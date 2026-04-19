@testable import SwiftVLC
import Foundation
import Testing

/// Exercises `Player` control APIs on a `--no-video --no-audio` VLC
/// instance (created per test via `TestInstance.makeAudioOnly`) so
/// `swift test` can drive the state machine headlessly.
///
/// Serialized because the integration tests all mutate the same
/// `@MainActor` `Player` fields; parallel execution would add
/// scheduling noise without changing coverage. CI also runs `swift
/// test --no-parallel` for the same reason.
///
/// State-transition waits use `subscribeAndAwait` /
/// `subscribeAndAwaitTerminalStop` — the subscription is set up
/// *before* the triggering action so no event can race past it. Each
/// wait is bounded by a 5-second hard timeout that fails the test
/// loudly if a signal never arrives.
@Suite(
  .tags(.integration, .mainActor, .async),
  .timeLimit(.minutes(1)),
  .serialized
)
@MainActor
struct PlayerControlTests {
  // MARK: - Idle-safe API coverage

  // These don't need real playback; they assert that the C wrapper calls
  // execute cleanly and the state machine observes the setters.

  @Test
  func `pause resume togglePlayPause on idle do not crash`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player.pause()
    player.resume()
    player.togglePlayPause()
    player.togglePlayPause()
    #expect(player.state == .idle)
  }

  @Test
  func `seek on idle player is a no-op`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player.seek(to: .milliseconds(500))
    player.seek(by: .milliseconds(200))
    #expect(player.state == .idle)
  }

  @Test
  func `nextFrame on idle player does not crash`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player.nextFrame()
    #expect(player.state == .idle)
  }

  @Test
  func `Setting nil renderer reverts to local`() throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    try player.setRenderer(nil)
  }

  @Test
  func `setDeinterlace accepts auto disable enable`() throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    try player.setDeinterlace(state: -1)
    try player.setDeinterlace(state: 0)
    try player.setDeinterlace(state: 1, mode: "blend")
  }

  // A-B loop APIs (`setABLoop`, `resetABLoop`) require libVLC to have
  // an active timeline and the debug libVLC rejects them before play
  // has produced a real media clock. They're exercised by the Showcase
  // apps' transport-control flow, not from this headless suite.

  @Test
  func `Equalizer attach and detach on idle player`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let eq = Equalizer()
    eq.preamp = 3.0
    player.equalizer = eq
    #expect(player.equalizer != nil)
    player.equalizer = nil
    #expect(player.equalizer == nil)
  }

  @Test
  func `rate setter updates libVLC state`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player.rate = 1.5
    // Rate is read back via libvlc_media_player_get_rate — no playback
    // needed for the C call itself to work.
    #expect(player.rate == 1.5)
  }

  @Test
  func `startRecording stopRecording on idle do not crash`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player.startRecording(to: NSTemporaryDirectory())
    player.stopRecording()
  }

  @Test
  func `Selecting nil audio track on idle player`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    // No tracks loaded yet; setter must handle the nil case without
    // crashing. Hits the `unselect_track_type` branch in `selectTrack`.
    player.selectedAudioTrack = nil
  }

  @Test
  func `Selecting nil subtitle track on idle player`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player.selectedSubtitleTrack = nil
  }

  // MARK: - Live playback

  //
  // Under `--no-video --no-audio` libVLC sprints through the demuxer
  // with no real render path to pace the stream, so `.playing` can
  // flip to `.stopped` in the same instant. We therefore don't assert
  // on synchronous `player.state` reads after `.playing` — the
  // regression we DO guard is "did the lifecycle emit the expected
  // events in order?", which is observable deterministically via the
  // event stream.
  //
  // Behavioral assertions around `pause`/`resume` during live playback
  // need the audio subsystem (libVLC synchronizes pause state through
  // the aout stream) and aren't viable headlessly — the shipped debug
  // libVLC trips `vlc_aout_stream_Play: pause_date == VLC_TICK_INVALID`.
  // Those paths are exercised by the Showcase apps and by anyone
  // running the suite inside Xcode with real audio/video devices.

  @Test
  func `Playback lifecycle emits playing then stopped`() async throws {
    let player = Player(instance: TestInstance.makeAudioOnly())

    // Subscribe for both terminal signals BEFORE play() so nothing can
    // race past the subscription.
    let playing = subscribeAndAwait(.playing, on: player)
    let terminated = subscribeAndAwaitTerminalStop(on: player)

    try player.play(Media(url: TestMedia.twosecURL))
    try #require(await playing.value, "player did not emit .playing within 5s")

    // `stop()` is idempotent with any natural end-of-media libVLC may
    // emit first; either path resolves `terminated.value`.
    player.stop()
    try #require(await terminated.value, "player did not emit stopped/stopping within 5s")
  }
}
