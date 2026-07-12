#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import Foundation
import Synchronization
import Testing

/// Exercises the `pipEvents` lifecycle stream on the sample-buffer
/// path by invoking the `AVPictureInPictureControllerDelegate`
/// callbacks directly — no real PiP window is needed, so everything
/// here runs headless. The `AVPictureInPictureController` argument is a
/// dummy the delegate methods never touch.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPEventsTests {
    private func makeDummyAVController(for controller: PiPController) -> AVPictureInPictureController {
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      return AVPictureInPictureController(contentSource: contentSource)
    }

    /// Drains exactly `count` events from the stream. Subscriptions are
    /// unbounded, so events emitted before this call are buffered and
    /// yield immediately.
    private func collect(
      _ count: Int,
      from stream: AsyncStream<PiPEvent>
    )
      async -> [PiPEvent] {
      var collected: [PiPEvent] = []
      for await event in stream {
        collected.append(event)
        if collected.count == count {
          break
        }
      }
      return collected
    }

    @Test
    func `willStart and didStart delegate callbacks emit events`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      // Assert before the first suspension: once this task suspends, the
      // KVO mirror of the controller's own (inactive) AVKit instance is
      // free to resync the flag.
      #expect(controller.isActive)

      let events = await collect(2, from: stream)
      guard case .willStart = events[0] else {
        Issue.record("Expected .willStart, got \(events[0])")
        return
      }
      guard case .didStart = events[1] else {
        Issue.record("Expected .didStart, got \(events[1])")
        return
      }
    }

    @Test
    func `failedToStart carries the delegate error`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let failure = NSError(domain: "swiftvlc.test.pip", code: 42)

      controller._setStateForTesting(isActive: true)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      let events = await collect(1, from: stream)
      guard case .failedToStart(let error) = events[0] else {
        Issue.record("Expected .failedToStart, got \(events[0])")
        return
      }
      let nsError = error as NSError
      #expect(nsError.domain == "swiftvlc.test.pip")
      #expect(nsError.code == 42)
      // failedToStart must also resync isActive to false.
      #expect(controller.isActive == false)
    }

    @Test
    func `restore then stop reports restoreRequested, plain stop reports userClosed`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let restored = Mutex(false)

      // Cycle 1: the user taps the restore affordance. With no
      // onRestoreUserInterface hook the completion runs immediately.
      controller.pictureInPictureController(
        avController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { ok in
          restored.withLock { $0 = ok }
        }
      )
      #expect(restored.withLock { $0 })
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      // Cycle 2: a stop with no discriminating signal is the close (X)
      // button on the sample-buffer path. Also proves didStop cleared
      // the pending reason from cycle 1.
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(4, from: stream)
      guard case .willStop(reason: .restoreRequested) = events[0] else {
        Issue.record("Expected .willStop(.restoreRequested), got \(events[0])")
        return
      }
      guard case .didStop(reason: .restoreRequested) = events[1] else {
        Issue.record("Expected .didStop(.restoreRequested), got \(events[1])")
        return
      }
      guard case .willStop(reason: .userClosed) = events[2] else {
        Issue.record("Expected .willStop(.userClosed), got \(events[2])")
        return
      }
      guard case .didStop(reason: .userClosed) = events[3] else {
        Issue.record("Expected .didStop(.userClosed), got \(events[3])")
        return
      }
    }

    @Test
    func `stop after natural end of media reports mediaEnded`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents

      // `.endReached` with inactive playback intent marks a natural end.
      #expect(player.isPlaybackRequestedActive == false)
      player._handleEventForTesting(.endReached)
      #expect(player.didReachEnd)

      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(2, from: stream)
      guard case .willStop(reason: .mediaEnded) = events[0] else {
        Issue.record("Expected .willStop(.mediaEnded), got \(events[0])")
        return
      }
      guard case .didStop(reason: .mediaEnded) = events[1] else {
        Issue.record("Expected .didStop(.mediaEnded), got \(events[1])")
        return
      }
    }

    /// The first discriminating signal wins: a recorded failure
    /// outranks the media-end fallback, and a recorded restore request
    /// is never overwritten by a later failure signal.
    @Test
    func `pending stop reason outranks media end and is not overwritten`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let failure = NSError(domain: "swiftvlc.test.pip", code: 7)

      // didReachEnd is set, but the failure signal takes precedence.
      player._handleEventForTesting(.endReached)
      #expect(player.didReachEnd)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      // Restore first, then a failure signal: restore sticks.
      controller.pictureInPictureController(
        avController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { _ in }
      )
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(4, from: stream)
      guard case .didStop(reason: .failure) = events[1] else {
        Issue.record("Expected .didStop(.failure), got \(events[1])")
        return
      }
      guard case .didStop(reason: .restoreRequested) = events[3] else {
        Issue.record("Expected .didStop(.restoreRequested), got \(events[3])")
        return
      }
    }

    @Test
    func `programmatic stop reports unknown`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents

      controller._setStateForTesting(isActive: true)
      controller.stop()
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(2, from: stream)
      guard case .willStop(reason: .unknown) = events[0] else {
        Issue.record("Expected .willStop(.unknown), got \(events[0])")
        return
      }
      guard case .didStop(reason: .unknown) = events[1] else {
        Issue.record("Expected .didStop(.unknown), got \(events[1])")
        return
      }
    }

    /// A fresh start clears any stale pending reason from a previous
    /// failed attempt, so the next stop resolves independently.
    @Test
    func `willStart clears a stale pending stop reason`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let failure = NSError(domain: "swiftvlc.test.pip", code: 1)

      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(4, from: stream)
      guard case .didStop(reason: .userClosed) = events[3] else {
        Issue.record("Expected .didStop(.userClosed), got \(events[3])")
        return
      }
    }

    @Test
    func `native backend active flips synthesize didStart and didStop unknown`() async {
      let player = Player(instance: TestInstance.shared)
      #if os(iOS)
      let backend = IOSNativePiPBackend()
      #else
      let backend = MacNativePiPBackend()
      #endif
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEvents

      controller.handleNativePictureInPictureActiveChanged(true)
      // A redundant flip must not double-emit.
      controller.handleNativePictureInPictureActiveChanged(true)
      controller.handleNativePictureInPictureActiveChanged(false)
      controller.handleNativePictureInPictureActiveChanged(false)

      let events = await collect(2, from: stream)
      guard case .didStart = events[0] else {
        Issue.record("Expected .didStart, got \(events[0])")
        return
      }
      guard case .didStop(reason: .unknown) = events[1] else {
        Issue.record("Expected .didStop(.unknown), got \(events[1])")
        return
      }
    }

    @Test
    func `pipEvents stream finishes when the controller deinits`() async throws {
      let player = Player(instance: TestInstance.shared)
      var controller: PiPController? = PiPController(player: player)
      let stream = try #require(controller?.pipEvents)

      controller = nil

      // The broadcaster terminates in deinit; the stream must finish
      // rather than suspend forever.
      for await event in stream {
        Issue.record("Expected no events, got \(event)")
      }
    }

    @Test
    func `multiple subscribers each receive every event`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let first = controller.pipEvents
      let second = controller.pipEvents

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      let firstEvents = await collect(2, from: first)
      let secondEvents = await collect(2, from: second)
      #expect(firstEvents.count == 2)
      #expect(secondEvents.count == 2)
      guard case .willStart = firstEvents[0], case .willStart = secondEvents[0] else {
        Issue.record("Both subscribers should see .willStart first")
        return
      }
    }
  }
}
#endif
