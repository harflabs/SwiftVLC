#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import Synchronization
import Testing

/// ``PiPController/pipSnapshots`` exists because ``PiPController/pipEvents``
/// carries transitions only. A subscriber attaching after PiP has already
/// started sees nothing until it stops, and auto-start makes that ordinary:
/// the system can begin PiP before any application code has subscribed.
///
/// Drained after terminating rather than awaited on an iterator. If the replay
/// were missing there would be nothing to receive, and awaiting would hang
/// instead of failing — a test that hangs on regression reports nothing.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPSnapshotTests {
    private func drain(_ stream: AsyncStream<PiPSnapshot>) async -> [PiPSnapshot] {
      var received: [PiPSnapshot] = []
      for await snapshot in stream {
        received.append(snapshot)
      }
      return received
    }

    /// Criterion 1: a late subscriber is told the authoritative current state
    /// rather than waiting for a change that may never come.
    @Test
    func `A late subscriber immediately receives the current snapshot`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      let stream = controller.pipSnapshots
      controller.pipSnapshotBroadcaster.terminate()

      let received = await drain(stream)
      #expect(received.count == 1)
      #expect(received.first?.isActive == controller.isActive)
      #expect(received.first?.isPossible == controller.isPossible)
    }

    /// Criterion 2: a start that happened before anyone subscribed must still
    /// be visible. On `pipEvents` that `didStart` is simply gone.
    @Test
    func `A start before subscription is not missed`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      controller.updatePiPActive(true)

      let stream = controller.pipSnapshots
      controller.pipSnapshotBroadcaster.terminate()

      let received = await drain(stream)
      #expect(received.last?.isActive == true, "a subscriber attaching after the start was told PiP was inactive")
    }

    /// Criterion 5: two subscribers converge on the same revision without
    /// either needing another transition to get there.
    @Test
    func `Multiple subscribers converge on the same revision`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      controller.updatePiPActive(true)

      let first = controller.pipSnapshots
      let second = controller.pipSnapshots
      controller.pipSnapshotBroadcaster.terminate()

      let a = await drain(first)
      let b = await drain(second)
      #expect(a.last?.revision == b.last?.revision)
      #expect(a.last == b.last)
    }

    /// The revision is what lets a consumer tell a newer snapshot from an
    /// older one without comparing every field.
    @Test
    func `The revision advances on each change`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      let stream = controller.pipSnapshots
      controller.updatePiPActive(true)
      controller.updatePiPActive(false)
      controller.pipSnapshotBroadcaster.terminate()

      let received = await drain(stream)
      let revisions = received.map(\.revision)
      #expect(revisions == revisions.sorted())
      #expect(Set(revisions).count == revisions.count, "two snapshots shared a revision")
    }

    /// The snapshot records which media it describes, because a media change
    /// tears PiP down and a stale snapshot would otherwise look current.
    @Test
    func `The snapshot carries the media generation it describes`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      try player.load(Media(url: TestMedia.twosecURL))

      controller.updatePiPActive(true)

      let stream = controller.pipSnapshots
      controller.pipSnapshotBroadcaster.terminate()

      let received = await drain(stream)
      #expect(received.last?.mediaGeneration == player.generation)
    }

    /// Criterion 3: a snapshot taken before the AVKit controller was recreated
    /// describes a controller that no longer exists. Pairing its active state
    /// with the new controller's identity is the confusion being prevented.
    @Test
    func `The snapshot names which controller its flags describe`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      let stream = controller.pipSnapshots
      controller.updatePiPActive(true)
      controller.pipSnapshotBroadcaster.terminate()

      let received = await drain(stream)
      #expect(received.allSatisfy { $0.controllerGeneration == controller.pipControllerGeneration })
    }

    /// Criterion 4: every AVKit signal reaches the main actor through a hop, so
    /// a controller replaced in the meantime can still deliver. Its state
    /// describes a session that is over and must not be applied.
    @Test
    func `A signal from a replaced controller is rejected`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      // Any identity that is not the installed controller will do. The player
      // is reused rather than constructing a second `PiPController`, which
      // would claim direct-PiP callback ownership on this same player as a
      // side effect of the test.
      #expect(controller.isCurrentAVController(ObjectIdentifier(player)) == false)
    }

    /// Criterion 4, exercised through the delegate rather than the predicate.
    ///
    /// A controller that was never installed stands in for one that has been
    /// replaced: AVKit signals reach the main actor through a hop, so the
    /// outgoing controller can still deliver a lifecycle callback after the
    /// incoming one is in place. Applying it would report the new controller as
    /// active on the strength of the old one's session.
    ///
    /// The installed controller is driven first, and that is load-bearing. It
    /// proves the callback does arrive within the observation window, so the
    /// negative assertion afterwards means "rejected" rather than "not yet
    /// delivered". Without it the test passes whether or not the guard exists,
    /// which is how the first version of it was hollow.
    @Test
    func `A delegate callback from a controller that is not installed is ignored`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let installed = try #require(controller.pipController)

      controller.pictureInPictureControllerDidStartPictureInPicture(installed)
      try #require(
        await poll(timeout: .seconds(2), until: { controller.isActive }),
        "the installed controller's callback never arrived, so the check below would prove nothing"
      )

      controller.pictureInPictureControllerDidStopPictureInPicture(installed)
      try #require(await poll(timeout: .seconds(2), until: { !controller.isActive }))

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let notInstalled = AVPictureInPictureController(contentSource: contentSource)

      controller.pictureInPictureControllerDidStartPictureInPicture(notInstalled)
      let leaked = try await poll(timeout: .milliseconds(500), until: { controller.isActive })
      #expect(
        leaked == false,
        "a callback from a controller that was never installed set the active flag"
      )
    }

    /// AVKit is owed the restore completion handler regardless of whether the
    /// callback is accepted. Returning without calling it leaves the teardown
    /// it drives unresolved, which is a worse failure than the stale state the
    /// guard exists to prevent.
    @Test
    func `A rejected restore callback still answers AVKit`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let notInstalled = AVPictureInPictureController(contentSource: contentSource)

      let answered = Mutex<Bool?>(nil)
      controller.pictureInPictureController(
        notInstalled,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
          answered.withLock { $0 = restored }
        }
      )

      try #require(
        await poll(timeout: .seconds(2), until: { answered.withLock { $0 } != nil }),
        "the completion handler was never called, leaving AVKit's teardown unresolved"
      )
      #expect(answered.withLock { $0 } == false)
    }

    /// Criterion 3 of issue 84: restore completes exactly once.
    ///
    /// `onRestoreUserInterface` is host application code holding an escaping
    /// callback. Nothing stops it answering twice, and AVKit's completion
    /// handler must run once — invoking a system completion handler more than
    /// once is undefined.
    @Test
    func `A restore hook that answers twice invokes AVKit once`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let installed = try #require(controller.pipController)

      controller.onRestoreUserInterface = { completion in
        completion(true)
        completion(true)
        completion(false)
      }

      let answers = Mutex<[Bool]>([])
      controller.pictureInPictureController(
        installed,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
          answers.withLock { $0.append(restored) }
        }
      )

      try #require(await poll(timeout: .seconds(2), until: { !answers.withLock { $0 }.isEmpty }))
      #expect(
        answers.withLock { $0 } == [true],
        "a restore hook answering repeatedly invoked AVKit's completion handler more than once"
      )
    }

    /// The other half of criterion 3: or a documented timeout.
    ///
    /// A hook that never answers would otherwise leave PiP teardown waiting
    /// with nothing to surface it. The bound reports `false`, since claiming a
    /// restore that did not happen is worse than reporting none.
    ///
    /// The bound is shortened here rather than waiting out the real one. An
    /// earlier version of this test only asserted the constant's value and that
    /// nothing had fired yet, which would have held whether or not the timeout
    /// was ever wired up.
    @Test
    func `A restore hook that never answers is bounded`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let installed = try #require(controller.pipController)

      let original = PiPController.restoreCompletionTimeout
      PiPController.restoreCompletionTimeout = .milliseconds(50)
      defer { PiPController.restoreCompletionTimeout = original }

      // Swallows the callback entirely.
      controller.onRestoreUserInterface = { _ in }

      let answered = Mutex<Bool?>(nil)
      controller.pictureInPictureController(
        installed,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
          answered.withLock { $0 = restored }
        }
      )

      try #require(
        await poll(timeout: .seconds(2), until: { answered.withLock { $0 } != nil }),
        "a restore hook that never answered left AVKit's completion handler unresolved"
      )
      #expect(answered.withLock { $0 } == false)
    }

    /// The bound must not pre-empt a hook that does answer, or every slow but
    /// legitimate restore would be reported as a failure.
    @Test
    func `A hook answering within the bound wins over the timeout`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let installed = try #require(controller.pipController)

      let original = PiPController.restoreCompletionTimeout
      PiPController.restoreCompletionTimeout = .seconds(5)
      defer { PiPController.restoreCompletionTimeout = original }

      controller.onRestoreUserInterface = { completion in completion(true) }

      let answers = Mutex<[Bool]>([])
      controller.pictureInPictureController(
        installed,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
          answers.withLock { $0.append(restored) }
        }
      )

      try #require(await poll(timeout: .seconds(2), until: { !answers.withLock { $0 }.isEmpty }))
      #expect(answers.withLock { $0 } == [true], "the timeout overrode a hook that answered in time")
    }

    /// A hook that answers immediately must not leave the bounded wait running.
    /// Without cancellation the sleeping task — and the completion closure it
    /// retains — stays alive for the full timeout after every restore, which is
    /// invisible in behaviour and only shows up as retention.
    ///
    /// The bound is stretched well past the assertion so a leaked task would
    /// still be sleeping when it is checked.
    @Test
    func `An immediate answer leaves no bounded wait running`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let installed = try #require(controller.pipController)

      let original = PiPController.restoreCompletionTimeout
      PiPController.restoreCompletionTimeout = .seconds(30)
      defer { PiPController.restoreCompletionTimeout = original }

      controller.onRestoreUserInterface = { completion in completion(true) }

      weak var leaked: AnyObject?
      do {
        let probe = RestoreRetentionProbe()
        leaked = probe
        controller.pictureInPictureController(
          installed,
          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { _ in
            _ = probe
          }
        )
      }

      try #require(
        await poll(timeout: .seconds(2), until: { leaked == nil }),
        "the completion closure was still retained after an immediate answer, so the bounded wait outlived it"
      )
    }

    /// Both flags travel in one value. Published from a single funnel they
    /// could otherwise describe a pair that was never simultaneously true.
    @Test
    func `A no-op update publishes nothing`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      let stream = controller.pipSnapshots
      controller.updatePiPActive(controller.isActive)
      controller.updatePiPPossible(controller.isPossible)
      controller.pipSnapshotBroadcaster.terminate()

      let received = await drain(stream)
      #expect(received.count == 1, "an unchanged flag published a redundant snapshot")
    }
  }
}
#endif

/// Stands in for anything the completion closure captures, so retention of the
/// closure is observable. `Sendable` because the closure it rides in is
/// `@Sendable`; it carries no state to race over.
private final class RestoreRetentionProbe: @unchecked Sendable {}
