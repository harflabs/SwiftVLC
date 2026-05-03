@testable import SwiftVLC
import Testing

/// Pins the values that `Player`'s live-read getters return when no
/// media is loaded, so any future libVLC version bump that introduces a
/// negative-sentinel return for these subsystems surfaces immediately
/// as a test failure.
///
/// Background: `volume` and `isMuted` already shadow the libVLC reads
/// because `libvlc_audio_get_volume` returns `-100` and
/// `libvlc_audio_get_mute` returns `-1` before the audio output has
/// been initialized. The other live-read getters (`rate`, `audioDelay`,
/// `subtitleDelay`, `subtitleTextScale`, `currentChapter`,
/// `currentTitle`, `teletextPage`) historically have NOT exhibited this
/// pattern in libVLC 4.0, but nothing in the libVLC contract guarantees
/// that. These tests lock down the observed behavior.
extension Integration {
  @MainActor
  struct PlayerLiveReadTests {
    /// `rate` returns `1.0` (libVLC's default) when no media is loaded.
    /// libVLC's `libvlc_media_player_get_rate` documentation does not
    /// promise a sentinel; this test pins the actual value.
    @Test func `rate without media returns 1.0`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.rate == 1.0)
    }

    /// `audioDelay` returns zero when no media is loaded. Negative
    /// values are valid (audio plays earlier), so a negative-sentinel
    /// would silently look like a delay request to a UI binding.
    @Test func `audioDelay without media returns zero`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.audioDelay == .zero)
    }

    /// `subtitleDelay` returns zero when no media is loaded. Same
    /// rationale as `audioDelay`: negative values are valid.
    @Test func `subtitleDelay without media returns zero`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.subtitleDelay == .zero)
    }

    /// `subtitleTextScale` returns `1.0` (100%) when no media is loaded.
    /// Range is `0.1...5.0`; a zero or negative would render subtitles
    /// invisible without explanation.
    @Test func `subtitleTextScale without media returns 1.0`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.subtitleTextScale == 1.0)
    }

    /// `currentChapter` returns `-1` when no media is loaded — this is
    /// libVLC's documented contract (header: "chapter number currently
    /// playing, or -1 if there is no media"). Surfaced to Swift callers
    /// as `Int`; consumers should check `chapterCount > 0` before
    /// trusting `currentChapter`.
    @Test func `currentChapter without media returns -1`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.currentChapter == -1)
    }

    /// `currentTitle` returns `-1` when no media is loaded — libVLC's
    /// documented contract. Same caveat as `currentChapter`.
    @Test func `currentTitle without media returns -1`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.currentTitle == -1)
    }

    /// `teletextPage` returns `100` when no media is loaded — libVLC's
    /// default initial page, which corresponds to the standard teletext
    /// index page across European teletext systems. NOT a sentinel
    /// indicating "off." Consumers wanting to check "is teletext
    /// active" should look at `currentMedia` and the relevant track
    /// list, not at `teletextPage`.
    @Test func `teletextPage without media returns 100 (default index)`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.teletextPage == 100)
    }

    /// Volume shadow correctly reports `1.0` (default unity) before
    /// audio output is initialized — guards against the `-100` sentinel
    /// from `libvlc_audio_get_volume`.
    @Test func `volume without media returns 1.0 (shadowed)`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.volume == 1.0)
    }

    /// Mute shadow correctly reports `false` before audio output is
    /// initialized — guards against the `-1` sentinel from
    /// `libvlc_audio_get_mute`.
    @Test func `isMuted without media returns false (shadowed)`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isMuted == false)
    }
  }
}
