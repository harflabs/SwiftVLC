#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Foundation
import Testing

/// Play pressed in the Picture in Picture window once playback has ended.
///
/// The direct and macOS backends route that press through
/// `PiPController.handleSetPlaying(true)`, which only knew how to resume. With
/// the player stopped there was nothing to resume, so it published an active
/// intent and returned: the window showed its pause glyph over media that
/// never played, and every further press only toggled the glyph. The native
/// iOS controller already started playback afresh in this state.
extension Integration {
  @Suite(.tags(.mainActor, .media))
  @MainActor struct PiPColdStartTests {
    @MainActor
    private final class Recorder {
      var resumeCount = 0
      var startCount = 0
      var shouldResume = false
      var startResult: Bool?

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { _, _ in .init(accepted: true, playbackControlRevision: nil) },
          resume: { _ in
            self.resumeCount += 1
            return true
          },
          cancelPendingPause: { _, _, _ in },
          shouldResume: { self.shouldResume },
          skip: { _ in .init(resolved: .rejected) },
          startStoppedPlayback: {
            self.startCount += 1
            return self.startResult
          }
        )
      }
    }

    private func makeController(
      _ recorder: Recorder
    ) -> (Player, PiPController) {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )
      return (player, controller)
    }

    @Test
    func `Play starts stopped playback instead of resuming`() {
      let recorder = Recorder()
      recorder.startResult = true
      recorder.shouldResume = true
      let (_, controller) = makeController(recorder)

      controller.handleSetPlaying(true)

      #expect(recorder.startCount == 1)
      #expect(recorder.resumeCount == 0, "a started session must not also be resumed")
      #expect(controller.pipPlaybackActive)
      #expect(controller.pendingPiPPlaybackState == true)
    }

    @Test
    func `A start that fails leaves the PiP window showing paused`() {
      let recorder = Recorder()
      recorder.startResult = false
      let (player, controller) = makeController(recorder)

      controller.handleSetPlaying(true)

      #expect(recorder.startCount == 1)
      #expect(recorder.resumeCount == 0)
      #expect(!controller.pipPlaybackActive)
      #expect(controller.pendingPiPPlaybackState == nil)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Play inside a session still resumes`() {
      let recorder = Recorder()
      recorder.startResult = nil
      recorder.shouldResume = true
      let (_, controller) = makeController(recorder)

      controller.handleSetPlaying(true)

      #expect(recorder.startCount == 1)
      #expect(recorder.resumeCount == 1)
      #expect(controller.pipPlaybackActive)
    }

    @Test
    func `Pause never consults the cold start`() {
      let recorder = Recorder()
      recorder.startResult = true
      let (_, controller) = makeController(recorder)

      controller.handleSetPlaying(false)

      #expect(recorder.startCount == 0)
    }

    /// Real decoding through vmem, so not gated on `TestCondition.canPlayMedia`:
    /// see `DecodedFrameHarnessTests` for why that gate does not apply here.
    @Test
    func `Play after the media ended starts it again`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let controller = PiPController(player: player)

      func decodedFrames() -> UInt64 {
        controller.renderer.telemetrySnapshot.decodedFrameCount
      }

      do {
        try player.play(url: TestMedia.testMP4URL)
        try #require(
          await poll(timeout: .seconds(10)) { decodedFrames() > 0 },
          "the first playback never decoded a frame"
        )
        try #require(
          await poll(timeout: .seconds(10)) { player.state == .stopped },
          "the one-second fixture never reached its end"
        )
        let framesAtEnd = decodedFrames()

        controller.handleSetPlaying(true)

        try #require(
          await poll(timeout: .seconds(10)) { decodedFrames() > framesAtEnd },
          "Play in the PiP window did not start the ended media again"
        )
        #expect(player.isPlaybackRequestedActive)
      } catch {
        await player.shutdown()
        throw error
      }
      await player.shutdown()
    }
  }
}
#endif
