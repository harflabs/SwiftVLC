#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVKit
import CoreMedia
import CustomDump
import Testing

/// Covers PiP skip: how AVKit's requested interval reaches the player, and
/// what happens when the resulting jump is refused.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerSkipTests {
    @MainActor
    final class PlaybackRecorder {
      var skipIntervals: [CMTime] = []
      var skipOutcome: PiPController.SkipOutcome = .issued

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { true },
          resume: { true },
          cancelPendingPause: {},
          shouldResume: { false },
          skip: { interval in
            self.skipIntervals.append(interval)
            return self.skipOutcome
          }
        )
      }
    }

    /// The interval AVKit asked for reaches the player unchanged.
    ///
    /// Bounds are deliberately *not* applied here any more. PiP used to
    /// convert the interval into an absolute target and clamp it against
    /// `currentTime` and `duration` before issuing a strict seek, which broke
    /// exactly where a DVR skip matters most: live and timeshift media have no
    /// duration to clamp against, and `currentTime` is itself an estimate
    /// between native clock samples, so rounding through it landed the skip
    /// somewhere other than the requested distance away. The relative jump is
    /// resolved against the input's own clock instead, and bounds are libVLC's
    /// to enforce.
    @Test
    func `A backwards skip from zero passes the interval through unclamped`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: -10, preferredTimescale: 1000))

      expectNoDifference(recorder.skipIntervals.map(\.seconds), [-10])
    }

    /// An overshoot past a known duration is libVLC's to bound, not PiP's.
    @Test
    func `A skip past duration passes the interval through unclamped`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(9),
        duration: .seconds(10)
      )
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: 60, preferredTimescale: 1000))

      expectNoDifference(recorder.skipIntervals.map(\.seconds), [60])
    }

    /// A mid-range skip fires exactly one jump carrying the requested offset.
    @Test
    func `A skip within bounds issues one jump with the requested interval`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(5),
        duration: .seconds(60)
      )
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: 3, preferredTimescale: 1000))

      expectNoDifference(recorder.skipIntervals.map(\.seconds), [3])
    }

    /// A refused jump must not be recorded as a skip that happened.
    ///
    /// The controller suppresses its timebase drift corrector for a second
    /// after each skip, so that the corrector does not fight a seek that is
    /// still settling. Arming that suppression for a skip libVLC refused blinds
    /// the corrector for a second over a timeline that never moved — precisely
    /// when it should be free to correct.
    @Test
    func `A rejected skip is not recorded as a skip`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(60))
      let recorder = PlaybackRecorder()
      recorder.skipOutcome = .rejected
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: 30, preferredTimescale: 1000))

      #expect(
        controller._didRecordSkipForTesting() == false,
        "a refused skip armed the drift-corrector suppression"
      )
    }

    /// The accepted counterpart, so the test above is proving a difference
    /// rather than an always-false property.
    @Test
    func `An accepted skip is recorded`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(60))
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: 30, preferredTimescale: 1000))

      #expect(controller._didRecordSkipForTesting())
    }

    /// AVKit's contract: the completion handler runs once the skip finishes or
    /// fails. Never twice, and never not at all — a missing call leaves the PiP
    /// transport spinning.
    @Test
    func `A skip calls its completion handler exactly once`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(60))
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )
      let interval = CMTime(seconds: 3, preferredTimescale: 1000)

      #expect(controller._skipCompletionCountForTesting(interval) == 1)

      recorder.skipOutcome = .rejected
      #expect(
        controller._skipCompletionCountForTesting(interval) == 1,
        "a refused skip must still complete, exactly once"
      )

      #expect(
        controller._skipCompletionCountForTesting(.invalid) == 1,
        "an unrepresentable interval must still complete, exactly once"
      )
    }
  }
}
#endif
