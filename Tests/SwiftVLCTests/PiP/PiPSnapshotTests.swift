#if os(iOS) || os(macOS)
@testable import SwiftVLC
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
