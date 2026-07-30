@testable import SwiftVLC
import Testing

extension Integration {
  /// `sessionGeneration` is what ``Player/recast(to:)`` uses to notice it no
  /// longer owns the session. It re-checks after each of its six suspension
  /// points and stops mutating once the check fails, so anything that changes
  /// the media has to advance it.
  ///
  /// It was advanced only by `load(_:)`, by the replacement branch of
  /// `play(_:)`, and by `recast` itself. A `MediaListPlayer` advancing the list
  /// calls `libvlc_media_list_player_next` directly and goes nowhere near it,
  /// so a playlist advance during an in-flight recast was invisible: the recast
  /// carried on reapplying track selection and transport state to media it no
  /// longer owned.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PlayerSessionGenerationTests {
    /// The gap, driven the way it actually happens.
    ///
    /// This used to poke `set_media` plus a synthesized `.mediaChanged` through
    /// a test seam, which was faithful until patch 0007. That patch drops the
    /// cached `p_md` field and routes `libvlc_media_player_get_media()` through
    /// `vlc_player_GetCurrentMedia()`, so `get_media()` now reports the media
    /// the player core is *using* rather than the one last handed to it. Its
    /// own header says as much: "the previous media is still returned until the
    /// switch is notified by the libvlc_MediaPlayerMediaChanged event."
    ///
    /// The seam therefore simulated a state libVLC can no longer produce. It
    /// set the media, reported the change immediately, and the handler read
    /// back the *old* media. Probing the new engine directly: the core adopts a
    /// media only when it has none, so no amount of `set_media` reproduces an
    /// external switch while another media is loaded. Only real playback does.
    ///
    /// So this drives a genuine list advance and waits for libVLC to report it.
    @Test(
      .tags(.async, .media),
      .enabled(if: TestCondition.canPlayMedia),
      .timeLimit(.minutes(1))
    )
    func `A list-player advance advances the generation`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player

      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      try list.append(Media(url: TestMedia.testMP4URL))
      listPlayer.mediaList = list

      listPlayer.play()
      // Stopped unconditionally: a `#require` that fails below would otherwise
      // leave this playing into whatever test runs next.
      defer { listPlayer.stop() }
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      let before = player.sessionGeneration

      // Straight to `libvlc_media_list_player_next`. No wrapper call asked for
      // this, and nothing on the way advances the generation by hand.
      try listPlayer.next()

      try #require(
        await poll(until: { player.sessionGeneration > before }),
        "a list advance left the generation stale, so recast cannot see it was superseded"
      )
    }

    /// The half that makes the fix safe rather than merely present, and the
    /// half that still runs without playback.
    ///
    /// `load(_:)` advances the generation itself and records the media it
    /// advanced for. libVLC then reports the same change back as
    /// `.mediaChanged`. Advancing again on that echo would supersede a recast
    /// started in between, for a change already accounted for.
    ///
    /// This one needs no player-core switch: the media `load(_:)` set is the
    /// media the core is using, so `get_media()` agrees with the recorded value
    /// under both the old and the new engine semantics.
    @Test
    func `The echo of a wrapper-initiated load does not advance it twice`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)
      let afterLoad = player.sessionGeneration

      // The native echo of that same load.
      player._handleEventForTesting(.mediaChanged)

      #expect(
        player.sessionGeneration == afterLoad,
        "the native echo of load(_:) advanced the generation a second time; a recast started in between would be spuriously superseded"
      )
    }
  }
}
