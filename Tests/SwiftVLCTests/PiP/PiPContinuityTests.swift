#if os(iOS)
@testable import SwiftVLC
import Dispatch
import Foundation
import Synchronization
import Testing

extension Logic {
  struct PiPContinuityTests {
    private final class Controller: @unchecked Sendable {}

    private final class WeakBox: @unchecked Sendable {
      weak var value: Controller?
    }

    private final class CoordinatorBox: @unchecked Sendable {
      var value: IOSNativePiPContinuityCoordinator?
    }

    private final class EventLog: @unchecked Sendable {
      private let storage = Mutex<[Marker]>([])

      func append(_ marker: Marker) {
        storage.withLock { $0.append(marker) }
      }

      var values: [Marker] {
        storage.withLock { $0 }
      }
    }

    private final class IdentityLog: @unchecked Sendable {
      private let storage = Mutex<[IOSNativePiPOutputIdentity?]>([])

      func append(_ identity: IOSNativePiPOutputIdentity?) {
        storage.withLock { $0.append(identity) }
      }

      var values: [IOSNativePiPOutputIdentity?] {
        storage.withLock { $0 }
      }
    }

    private enum Marker: Equatable, Sendable {
      case rebuilding(UInt64, UInt64)
      case restored(UInt64, UInt64)
      case timedOut(UInt64, UInt64)
    }

    private enum TakeMarker: Equatable, Sendable {
      case preserved(ObjectIdentifier)
      case createFresh
      case superseded
    }

    private static func output(
      _ nativeHandle: UInt64,
      _ generation: UInt64,
      _ output: UInt64
    ) -> IOSNativePiPOutputIdentity {
      IOSNativePiPOutputIdentity(
        nativeHandle: nativeHandle,
        playbackGeneration: PlaybackGeneration(generation),
        output: output
      )
    }

    private static func marker(
      _ transition: IOSNativePiPContinuityCoordinator.Transition
    ) -> Marker {
      switch transition {
      case .rebuilding(let previous, let successor):
        .rebuilding(previous.value, successor.value)
      case .restored(let previous, let successor, _):
        .restored(previous.value, successor.value)
      case .timedOut(let previous, let successor, _):
        .timedOut(previous.value, successor.value)
      }
    }

    private static func marker(
      _ outcome: IOSNativePiPContinuityCoordinator.PreservedControllerTakeOutcome
    ) -> TakeMarker {
      switch outcome {
      case .preserved(let controller):
        .preserved(ObjectIdentifier(controller))
      case .createFresh:
        .createFresh
      case .superseded:
        .superseded
      }
    }

    private static func makeCoordinator(
      wait: DispatchTimeInterval = .milliseconds(50),
      events: EventLog = EventLog()
    ) -> IOSNativePiPContinuityCoordinator {
      IOSNativePiPContinuityCoordinator(expectedHandoffWait: wait) { transition in
        events.append(marker(transition))
      }
    }

    @discardableResult
    private static func makeFreshReady(
      _ coordinator: IOSNativePiPContinuityCoordinator,
      controller: Controller,
      output: IOSNativePiPOutputIdentity
    ) -> Bool {
      guard
        case .createFresh = coordinator.takePreservedControllerOutcome(for: output),
        coordinator.didClaimFreshController(controller, output: output)
      else { return false }
      return coordinator.didBecomeReady(controller, output: output)
    }

    private static func waitUntil(
      timeout: Duration = .seconds(1),
      _ predicate: @escaping @Sendable () -> Bool
    )
      async throws -> Bool {
      let deadline = ContinuousClock.now + timeout
      while !predicate() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(2))
      }
      return true
    }

    @Test
    func `fresh output must claim its exact controller before readiness`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let wrongController = Controller()
      let outputA = Self.output(101, 1, 1)
      let staleOutput = Self.output(101, 1, 2)

      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputA)) == .createFresh)
      #expect(!coordinator.didBecomeReady(controller, output: outputA))
      coordinator.didCancel(wrongController, output: outputA)
      #expect(coordinator.didClaimFreshController(controller, output: outputA))
      #expect(coordinator.didClaimFreshController(controller, output: outputA))
      #expect(!coordinator.didClaimFreshController(wrongController, output: outputA))

      coordinator.didCancel(controller, output: staleOutput)
      #expect(coordinator.didBecomeReady(controller, output: outputA))
      #expect(coordinator.isCurrentReady(controller, output: outputA))
      #expect(!coordinator.isCurrentReady(wrongController, output: outputA))
    }

    @Test
    func `unclaimed creation failure rolls back only its exact reservation`() {
      let coordinator = Self.makeCoordinator()
      let outputA = Self.output(102, 1, 3)
      let wrongOutput = Self.output(102, 1, 4)
      let controller = Controller()

      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputA)) == .createFresh)
      #expect(!coordinator.rollbackUnclaimedFreshController(output: wrongOutput))
      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputA)) == .createFresh)
      #expect(coordinator.rollbackUnclaimedFreshController(output: outputA))

      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputA)) == .createFresh)
      #expect(coordinator.didClaimFreshController(controller, output: outputA))
      #expect(!coordinator.rollbackUnclaimedFreshController(output: outputA))
      #expect(coordinator.didBecomeReady(controller, output: outputA))
    }

    @Test
    func `distinct native handles transfer one controller with ordered lifecycle`() {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(events: events)
      let controller = Controller()
      let outputA = Self.output(201, 11, 11)
      let outputB = Self.output(202, 12, 12)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))
      #expect(coordinator.didBecomeReady(controller, output: outputB))

      #expect(!coordinator.isCurrentReady(controller, output: outputA))
      #expect(coordinator.isCurrentReady(controller, output: outputB))
      #expect(events.values == [
        .rebuilding(11, 12),
        .restored(11, 12)
      ])
    }

    @Test
    func `successor waits until retiring output preserves the controller`() async throws {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(wait: .seconds(2), events: events)
      let controller = Controller()
      let outputA = Self.output(301, 21, 21)
      let outputB = Self.output(302, 22, 22)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      let take = Task.detached {
        Self.marker(coordinator.takePreservedControllerOutcome(for: outputB))
      }
      try #require(await Self.waitUntil {
        coordinator._isWaitingForExpectedHandoffForTesting(outputB)
      })

      #expect(coordinator.preserve(controller, from: outputA))
      #expect(await take.value == .preserved(ObjectIdentifier(controller)))
      #expect(coordinator.didClaimFreshController(controller, output: outputB))
      #expect(coordinator.didBecomeReady(controller, output: outputB))
      #expect(events.values == [
        .rebuilding(21, 22),
        .restored(21, 22)
      ])
    }

    @Test
    func `A to B to C supersedes B before A preserves`() {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(events: events)
      let controller = Controller()
      let outputA = Self.output(401, 31, 31)
      let outputB = Self.output(402, 32, 32)
      let outputC = Self.output(403, 33, 33)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.expectHandoff(to: outputC.binding))
      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputB)) == .superseded)
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))

      #expect(events.values == [
        .rebuilding(31, 33),
        .restored(31, 33)
      ])
    }

    @Test
    func `C retargets an A controller already preserved for B`() {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(events: events)
      let controller = Controller()
      let outputA = Self.output(501, 41, 41)
      let outputB = Self.output(502, 42, 42)
      let outputC = Self.output(503, 43, 43)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.expectHandoff(to: outputC.binding))

      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputB)) == .superseded)
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))
      #expect(events.values == [
        .rebuilding(41, 42),
        .rebuilding(41, 43),
        .restored(41, 43)
      ])
    }

    @Test
    func `taken B can return controller into C before preparing`() {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(events: events)
      let controller = Controller()
      let outputA = Self.output(601, 51, 51)
      let outputB = Self.output(602, 52, 52)
      let outputC = Self.output(603, 53, 53)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))

      #expect(coordinator.expectHandoff(to: outputC.binding))
      #expect(!coordinator.didBecomeReady(controller, output: outputB))
      #expect(coordinator.preserve(controller, from: outputB))
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))
      #expect(events.values == [
        .rebuilding(51, 52),
        .rebuilding(51, 53),
        .restored(51, 53)
      ])
    }

    @Test
    func `stale A cannot steal controller after B takes ownership`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let outputA = Self.output(651, 56, 56)
      let outputB = Self.output(652, 57, 57)
      let outputC = Self.output(653, 58, 58)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))
      #expect(coordinator.expectHandoff(to: outputC.binding))

      #expect(!coordinator.preserve(controller, from: outputA))
      #expect(coordinator.preserve(controller, from: outputB))
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))
    }

    @Test
    func `late B cancel timeout and readiness cannot mutate ready C`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let outputA = Self.output(701, 61, 61)
      let outputB = Self.output(702, 62, 62)
      let outputC = Self.output(703, 63, 63)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))
      #expect(coordinator.expectHandoff(to: outputC.binding))
      #expect(coordinator.preserve(controller, from: outputB))
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))

      coordinator.didCancel(controller, output: outputB)
      coordinator.didTimeOut(controller, output: outputB)
      #expect(!coordinator.didBecomeReady(controller, output: outputB))
      #expect(coordinator.isCurrentReady(controller, output: outputC))
    }

    @Test
    func `delayed B delivery is rejected after C becomes current ready`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let outputA = Self.output(751, 66, 66)
      let outputB = Self.output(752, 67, 67)
      let outputC = Self.output(753, 68, 68)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))
      #expect(coordinator.didBecomeReady(controller, output: outputB))

      // B's MainActor delivery may still be queued after its synchronous
      // coordinator commit. C completes first, so that delayed B task must
      // fail its exact revalidation before reserving a callback generation.
      #expect(coordinator.expectHandoff(to: outputC.binding))
      #expect(coordinator.preserve(controller, from: outputB))
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))
      #expect(!coordinator.isCurrentReady(controller, output: outputB))
      #expect(coordinator.isCurrentReady(controller, output: outputC))
    }

    @Test
    func `controller stays retained from take through exact cancel`() throws {
      let coordinator = Self.makeCoordinator()
      let weakController = WeakBox()
      let outputA = Self.output(801, 71, 71)
      let outputB = Self.output(802, 72, 72)

      var controller: Controller? = Controller()
      weakController.value = controller
      #expect(try Self.makeFreshReady(
        coordinator,
        controller: #require(controller),
        output: outputA
      ))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(try coordinator.preserve(#require(controller), from: outputA))
      var taken: AnyObject? = coordinator.takePreservedController(for: outputB)
      #expect(taken === controller)
      controller = nil
      taken = nil

      #expect(weakController.value != nil, "Pending must strongly own the taken controller")
      try coordinator.didCancel(#require(weakController.value), output: outputB)
      #expect(weakController.value == nil)
    }

    @Test
    func `preparation timeout wins exactly once`() {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(events: events)
      let controller = Controller()
      let outputA = Self.output(901, 81, 81)
      let outputB = Self.output(902, 82, 82)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))

      coordinator.didTimeOut(controller, output: outputB)
      coordinator.didTimeOut(controller, output: outputB)
      coordinator.didCancel(controller, output: outputB)
      #expect(!coordinator.didBecomeReady(controller, output: outputB))
      #expect(events.values == [
        .rebuilding(81, 82),
        .timedOut(81, 82)
      ])
    }

    @Test
    func `readiness disarms both old and current timeout callbacks`() {
      let events = EventLog()
      let coordinator = Self.makeCoordinator(events: events)
      let controller = Controller()
      let outputA = Self.output(1001, 91, 91)
      let outputB = Self.output(1002, 92, 92)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputB))
      #expect(coordinator.didBecomeReady(controller, output: outputB))

      coordinator.didTimeOut(controller, output: outputA)
      coordinator.didTimeOut(controller, output: outputB)
      #expect(coordinator.isCurrentReady(controller, output: outputB))
      #expect(events.values == [
        .rebuilding(91, 92),
        .restored(91, 92)
      ])
    }

    @Test
    func `wait deadline cannot authorize a duplicate while predecessor is ready`() {
      let coordinator = Self.makeCoordinator(wait: .nanoseconds(0))
      let controller = Controller()
      let outputA = Self.output(1101, 101, 101)
      let firstB = Self.output(1102, 102, 102)
      let retryB = Self.output(1102, 102, 103)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: firstB.binding))
      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: firstB)) == .superseded)
      #expect(coordinator.isCurrentReady(controller, output: outputA))

      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: retryB) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: retryB))
      #expect(coordinator.didBecomeReady(controller, output: retryB))
    }

    @Test
    func `fresh fallback requires exact proof predecessor closed`() {
      let coordinator = Self.makeCoordinator(wait: .nanoseconds(0))
      let controllerA = Controller()
      let controllerB = Controller()
      let outputA = Self.output(1201, 111, 111)
      let outputB = Self.output(1202, 112, 112)

      #expect(Self.makeFreshReady(coordinator, controller: controllerA, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      coordinator.didCancel(controllerA, output: outputA)

      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputB)) == .createFresh)
      #expect(coordinator.didClaimFreshController(controllerB, output: outputB))
      #expect(coordinator.didBecomeReady(controllerB, output: outputB))
    }

    /// libVLC closes and reopens the display on the same player whenever the
    /// stream changes resolution, which every adaptive stream does. The
    /// closed output's cancel used to retire its whole handle-and-media
    /// binding, so the reopened output was refused a controller and PiP stayed
    /// unavailable for the rest of the media.
    @Test
    func `rebuilt output on the same binding gets a fresh controller after cancel`() {
      let coordinator = Self.makeCoordinator(wait: .nanoseconds(0))
      let first = Controller()
      let second = Controller()
      let third = Controller()
      let firstOutput = Self.output(1251, 115, 115)
      let rebuiltOutput = Self.output(1251, 115, 116)
      let rebuiltAgain = Self.output(1251, 115, 117)

      #expect(Self.makeFreshReady(coordinator, controller: first, output: firstOutput))
      // No handoff is staged for a same-player rebuild, so an active
      // controller is not carried across; it is closed and cancelled.
      #expect(!coordinator.preserve(first, from: firstOutput))
      coordinator.didCancel(first, output: firstOutput)

      #expect(
        Self.marker(coordinator.takePreservedControllerOutcome(for: rebuiltOutput))
          == .createFresh
      )
      #expect(coordinator.didClaimFreshController(second, output: rebuiltOutput))
      #expect(coordinator.didBecomeReady(second, output: rebuiltOutput))
      #expect(coordinator.isCurrentReady(second, output: rebuiltOutput))

      // The retired output itself stays retired.
      #expect(!coordinator.didBecomeReady(first, output: firstOutput))
      #expect(coordinator.isCurrentReady(second, output: rebuiltOutput))

      // And the next rebuild works the same way.
      coordinator.didCancel(second, output: rebuiltOutput)
      #expect(Self.makeFreshReady(coordinator, controller: third, output: rebuiltAgain))
    }

    /// The same applies to an output that closes before its controller ever
    /// became ready.
    @Test
    func `rebuilt output gets a fresh controller after an unprepared one is cancelled`() {
      let coordinator = Self.makeCoordinator(wait: .nanoseconds(0))
      let first = Controller()
      let second = Controller()
      let firstOutput = Self.output(1261, 116, 118)
      let rebuiltOutput = Self.output(1261, 116, 119)

      #expect(
        Self.marker(coordinator.takePreservedControllerOutcome(for: firstOutput))
          == .createFresh
      )
      #expect(coordinator.didClaimFreshController(first, output: firstOutput))
      coordinator.didCancel(first, output: firstOutput)

      #expect(Self.makeFreshReady(coordinator, controller: second, output: rebuiltOutput))
    }

    /// Media-list navigation changes the media behind a live output without
    /// changing its identity. That path retires the binding explicitly and
    /// must keep failing closed.
    @Test
    func `explicitly retired binding still refuses a rebuilt output`() {
      let coordinator = Self.makeCoordinator(wait: .nanoseconds(0))
      let controller = Controller()
      let firstOutput = Self.output(1271, 117, 120)
      let rebuiltOutput = Self.output(1271, 117, 121)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: firstOutput))
      #expect(coordinator.retireBindings(forNativeHandle: 1271))
      coordinator.didCancel(controller, output: firstOutput)

      #expect(
        Self.marker(coordinator.takePreservedControllerOutcome(for: rebuiltOutput))
          == .superseded
      )
    }

    @Test
    func `same handle media change and unstaged second output fail closed`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let outputA = Self.output(1301, 121, 121)
      let sameHandleNewMedia = Self.output(1301, 122, 122)
      let unstagedOtherHandle = Self.output(1302, 122, 123)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(!coordinator.expectHandoff(to: sameHandleNewMedia.binding))
      #expect(
        Self.marker(coordinator.takePreservedControllerOutcome(for: sameHandleNewMedia))
          == .superseded
      )
      #expect(!coordinator.isCurrentReady(controller, output: outputA))

      let cleanCoordinator = Self.makeCoordinator()
      #expect(Self.makeFreshReady(cleanCoordinator, controller: controller, output: outputA))
      #expect(
        Self.marker(cleanCoordinator.takePreservedControllerOutcome(for: unstagedOtherHandle))
          == .superseded
      )
      #expect(cleanCoordinator.isCurrentReady(controller, output: outputA))
    }

    @Test
    func `explicit media-list invalidation rejects existing and delayed readiness`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let outputA = Self.output(1401, 131, 131)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.retireBindings(forNativeHandle: 1401))
      #expect(!coordinator.isCurrentReady(controller, output: outputA))
      #expect(!coordinator.didBecomeReady(controller, output: outputA))
      coordinator.didCancel(controller, output: outputA)
      #expect(!coordinator.retireBindings(forNativeHandle: 1401))
    }

    @Test
    func `ready identity snapshot is coherent and nil outside exact readiness`() async {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let outputA = Self.output(1451, 136, 136)
      let outputB = Self.output(1452, 137, 137)

      #expect(coordinator.currentReadyOutputIdentity() == nil)
      #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: outputA)) == .createFresh)
      #expect(coordinator.didClaimFreshController(controller, output: outputA))
      #expect(coordinator.currentReadyOutputIdentity() == nil)
      #expect(coordinator.didBecomeReady(controller, output: outputA))
      #expect(coordinator.currentReadyOutputIdentity() == outputA)

      let observed = IdentityLog()
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
          group.addTask {
            for _ in 0..<128 {
              let snapshot = coordinator.currentReadyOutputIdentity()
              observed.append(snapshot)
            }
          }
        }
        group.addTask {
          guard
            coordinator.expectHandoff(to: outputB.binding),
            coordinator.preserve(controller, from: outputA),
            coordinator.takePreservedController(for: outputB) === controller,
            coordinator.didClaimFreshController(controller, output: outputB)
          else { return }
          _ = coordinator.didBecomeReady(controller, output: outputB)
        }
      }

      #expect(observed.values.allSatisfy { $0 == outputA || $0 == outputB })
      #expect(coordinator.currentReadyOutputIdentity() == outputB)
      #expect(!coordinator.retireControllers(forNativeHandle: 1452).isEmpty)
      #expect(coordinator.currentReadyOutputIdentity() == nil)
    }

    @Test
    func `transition emission remains FIFO under reentrant retargeting`() {
      let events = EventLog()
      let coordinatorBox = CoordinatorBox()
      let outputC = Self.output(1503, 143, 143)
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        let value = Self.marker(transition)
        events.append(value)
        if value == .rebuilding(141, 142) {
          #expect(coordinatorBox.value?.expectHandoff(to: outputC.binding) == true)
        }
      }
      coordinatorBox.value = coordinator
      let controller = Controller()
      let outputA = Self.output(1501, 141, 141)
      let outputB = Self.output(1502, 142, 142)

      #expect(Self.makeFreshReady(coordinator, controller: controller, output: outputA))
      #expect(coordinator.expectHandoff(to: outputB.binding))
      #expect(coordinator.preserve(controller, from: outputA))
      #expect(coordinator.takePreservedController(for: outputC) === controller)
      #expect(coordinator.didClaimFreshController(controller, output: outputC))
      #expect(coordinator.didBecomeReady(controller, output: outputC))
      #expect(events.values == [
        .rebuilding(141, 142),
        .rebuilding(141, 143),
        .restored(141, 143)
      ])
    }

    @Test
    func `legacy generation-only entry points are fail closed`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let generation = PlaybackGeneration(151)

      coordinator.expectHandoff(for: generation)
      #expect(!coordinator.preserve(controller, for: generation))
      #expect(coordinator.takePreservedController(for: generation) == nil)
      #expect(!coordinator.didBecomeReady(controller, mediaGeneration: generation))
      coordinator.didTimeOut(controller)
    }

    @Test
    func `zero and saturated identities are rejected without mutation`() {
      let coordinator = Self.makeCoordinator()
      let controller = Controller()
      let zeroHandle = Self.output(0, 1, 1)
      let zeroGeneration = Self.output(1, 0, 1)
      let zeroOutput = Self.output(1, 1, 0)
      let saturatedOutput = Self.output(1, 1, .max)

      for invalid in [zeroHandle, zeroGeneration, zeroOutput, saturatedOutput] {
        #expect(Self.marker(coordinator.takePreservedControllerOutcome(for: invalid)) == .superseded)
        #expect(!coordinator.didClaimFreshController(controller, output: invalid))
        #expect(!coordinator.didBecomeReady(controller, output: invalid))
      }
    }

    @Test
    func `native handle lifetime identity never derives from a reused address`() throws {
      let reusedAddress = try #require(OpaquePointer(bitPattern: 0x1234))
      let first = NativePlayerHandleLifetime(pointer: reusedAddress)
      let second = NativePlayerHandleLifetime(pointer: reusedAddress)

      #expect(first.nativePiPHandleIdentity != 0)
      #expect(second.nativePiPHandleIdentity != 0)
      #expect(first.nativePiPHandleIdentity != second.nativePiPHandleIdentity)
      #expect(second.nativePiPHandleIdentity > first.nativePiPHandleIdentity)
    }
  }
}
#endif
