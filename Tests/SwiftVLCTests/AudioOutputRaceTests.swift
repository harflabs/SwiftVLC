@testable import SwiftVLC
import Foundation
import Testing

/// Reproduction tests for the libVLC debug-build audio-output assertion
/// `assert(stream->timing.pause_date == VLC_TICK_INVALID)` at
/// `src/audio_output/dec.c:876` (and a twin at `dec.c:991` on the
/// pause-entry side). The Showcase uses the default `VLCInstance`
/// (audio-output enabled), so a user who dismisses a screen while the
/// aout is still opening — or who rapid-toggles pause/resume before the
/// first buffer lands — hits that assertion and kills the process.
///
/// These tests build a fresh `VLCInstance(arguments: ["--quiet"])` so
/// the full audio path runs exactly as in the Showcase (audio enabled),
/// unlike the rest of the integration suite which forces `--no-audio`
/// via `TestInstance.makeAudioOnly()`.
///
/// Each scenario targets one narrow window documented in
/// `Player.togglePlayPause` and `TestInstance.swift`:
/// - aout initialization racing with `deinit`'s offloaded stop+release
/// - rapid pause/resume interleaved with the aout opening path
/// - stop fired before `.playing` is ever reached
/// - mixed pause/resume/stop at sub-10ms cadence
/// - concurrent `togglePlayPause` calls from multiple tasks
extension Integration {
  @Suite(.tags(.mainActor, .async, .media), .serialized)
  @MainActor struct AudioOutputRaceTests {
    /// A fresh audio-enabled instance. Not shared: each test wants its
    /// own aout state so one test's assertion can't be blamed on a
    /// leaked decoder from a previous test.
    private static func makeAudioInstance() -> VLCInstance {
      // `--quiet` silences the log flood from 30–50 iterations of
      // opening/closing audio outputs; everything else is left at the
      // same defaults the Showcase uses.
      try! VLCInstance(arguments: ["--quiet"])
    }

    // MARK: - a) play → immediately drop (no stop, no wait)

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `play then immediately drop racing aout open`() throws {
      // Each `Player` is created, told to play, and dropped on the same
      // tick. `Player.deinit` dispatches `libvlc_media_player_stop_async`
      // + `libvlc_media_player_release` to the utility queue; those
      // collide with the aout opener's first buffer path, which is the
      // crash class we're trying to surface.
      let instance = Self.makeAudioInstance()
      for _ in 0..<30 {
        let player = Player(instance: instance)
        try player.play(Media(url: TestMedia.twosecURL))
      }
    }

    // MARK: - b) play → reach .playing → rapid pause/resume

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(2)))
    func `rapid pause resume after reaching playing`() async throws {
      // Trips the dec.c:991 twin: `assert(pause_date == VLC_TICK_INVALID)`
      // on the pause-entry side. If two pauses land inside the same
      // `vlc_aout_stream_ChangePause` window without the unpause
      // clearing `pause_date`, the assertion fires.
      let instance = Self.makeAudioInstance()
      let player = Player(instance: instance)
      let playing = subscribeAndAwait(.playing, on: player)
      try player.play(Media(url: TestMedia.twosecURL))
      try await requireReached(playing, "player never reached .playing")

      for _ in 0..<50 {
        player.pause()
        player.resume()
      }
      player.stop()
    }

    // MARK: - c) play → stop mid-initialization (before .playing)

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `stop before reaching playing`() throws {
      // Fire-and-forget `stop()` before the aout has had a chance to
      // emit its first buffer. This is the Showcase pattern: user taps
      // back, `.onDisappear` calls `player.stop()`, aout is still mid-
      // open. `stop_async` has to tear down an aout that hasn't
      // finished constructing its `stream->timing` state yet.
      let instance = Self.makeAudioInstance()
      for _ in 0..<30 {
        let player = Player(instance: instance)
        try player.play(Media(url: TestMedia.twosecURL))
        // No wait — immediately stop. This is the tight window.
        player.stop()
      }
    }

    // MARK: - d) play → pause → resume → pause → stop at sub-10ms cadence

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(2)))
    func `pause resume pause stop sub ten ms cadence`() async throws {
      // Walks the full pause/resume ladder and then tears down, all
      // before libVLC's own timing pipeline has converged. Sleep
      // deliberately short (<10ms) so each stage lands inside the same
      // aout-opener window.
      let instance = Self.makeAudioInstance()
      for _ in 0..<20 {
        let player = Player(instance: instance)
        try player.play(Media(url: TestMedia.twosecURL))
        try? await Task.sleep(for: .milliseconds(5))
        player.pause()
        try? await Task.sleep(for: .milliseconds(5))
        player.resume()
        try? await Task.sleep(for: .milliseconds(5))
        player.pause()
        try? await Task.sleep(for: .milliseconds(5))
        player.stop()
      }
    }

    // MARK: - e) togglePlayPause from multiple tasks

    /// Hypothesis probe: confirms that 200 rapid `togglePlayPause`
    /// calls race against libVLC's aout state machine. The assertion
    /// `stream->timing.pause_date == VLC_TICK_INVALID` in
    /// `src/audio_output/dec.c:876` is an upstream debug-build guard
    /// and the test reliably trips it after enough accumulated
    /// per-instance aout state. Disabled because fixing the race
    /// requires a libVLC patch (it's a known upstream issue documented
    /// in ``TestInstance``), and keeping the probe enabled would crash
    /// every CI run. Re-enable when investigating the race directly
    /// against a patched libVLC build.
    @Test(.disabled("Upstream libVLC debug-assert race; see test doc and TestInstance.swift"))
    func `concurrent togglePlayPause from multiple tasks`() async throws {
      let instance = Self.makeAudioInstance()
      let player = Player(instance: instance)
      let playing = subscribeAndAwait(.playing, on: player)
      try player.play(Media(url: TestMedia.twosecURL))
      try await requireReached(playing, "player never reached .playing")

      for _ in 0..<200 {
        player.togglePlayPause()
        await Task.yield()
      }
      player.stop()
    }
  }
}
