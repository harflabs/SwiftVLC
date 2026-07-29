#if os(iOS) || os(macOS)
@testable import SwiftVLC
import Testing

extension Integration {
  /// PiP's state observer is the consumer issue #78 was filed about. The lane
  /// split landed, but this observer kept reading the mixed `events` stream,
  /// so the guarantee existed without reaching the code that needed it.
  ///
  /// What a loss costs here is not cosmetic: `.seekableChanged` is one-shot, so
  /// dropping it leaves the controller on the conservative media-changed reset
  /// for the rest of the session — linear playback, no skip controls, on media
  /// that is in fact seekable.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PiPStateObserverLaneTests {
    /// Drains the observer until it has processed the sentinel, or gives up.
    ///
    /// The sentinel is broadcast last, so it survives a newest-wins buffer
    /// whether or not the fix is present. That is what makes the assertion
    /// after it meaningful rather than a race: reaching it proves the observer
    /// ran and drained, so a missing earlier event was dropped, not pending.
    private func drainObserver(of controller: PiPController, untilDurationIs milliseconds: Int64) async -> Bool {
      for _ in 0..<2000 {
        if controller.playbackStateObservation.durationMilliseconds == milliseconds {
          return true
        }
        await Task.yield()
      }
      return false
    }

    @Test(.timeLimit(.minutes(1)))
    func `A timing burst cannot evict the seekability the observer needs`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)

      // Broadcast first, so it sits on the oldest side of the backlog — where
      // a newest-wins buffer evicts.
      bridge._broadcastForTesting(.seekableChanged(true), source: source)
      // Both observer tasks are @MainActor and so is this test, so none of
      // this is delivered until the first suspension below: the whole burst
      // queues against a stalled consumer, which is the real-world condition.
      for index in 0..<500 {
        bridge._broadcastForTesting(.timeChanged(.milliseconds(index)), source: source)
        bridge._broadcastForTesting(.positionChanged(Double(index) / 500), source: source)
      }
      bridge._broadcastForTesting(.lengthChanged(.seconds(7)), source: source)

      #expect(
        await drainObserver(of: controller, untilDurationIs: 7000),
        "the observer never processed the sentinel; the assertion below would be racing"
      )
      #expect(
        controller.playbackStateObservation.isSeekable,
        "a 1000-event timing burst evicted the seekability change, pinning PiP to linear playback"
      )
    }

    /// The other half: the observer must still converge from clock ticks. The
    /// timing lane is what makes duration and seekability reachable during
    /// steady playback, when no further state transition arrives — so routing
    /// control events losslessly must not come at the cost of dropping the
    /// tick that drives convergence.
    @Test(.timeLimit(.minutes(1)))
    func `The observer still reacts to timing events`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)

      bridge._broadcastForTesting(.lengthChanged(.seconds(3)), source: source)
      #expect(await drainObserver(of: controller, untilDurationIs: 3000))

      // A tick alone, with no control event following it, has to reach the
      // observer. Asserting on the timing lane's own delivery rather than on a
      // downstream effect keeps this independent of capability polling.
      var sawTick = false
      let timing = player.timingEvents
      bridge._broadcastForTesting(.timeChanged(.milliseconds(42)), source: source)
      for await event in timing {
        if case .timeChanged = event {
          sawTick = true
          break
        }
      }

      #expect(sawTick, "the timing lane stopped delivering clock ticks")
    }
  }
}
#endif
