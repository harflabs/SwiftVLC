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
    /// The gap. A media change SwiftVLC did not originate still has to
    /// supersede whatever was restoring the previous one.
    @Test
    func `A media change from outside the wrapper advances the generation`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let before = player.sessionGeneration

      // What a list-player advance looks like from here: libVLC swapped the
      // input and reported it, without any wrapper call having asked for it.
      try player.adoptMediaForTesting(Media(url: TestMedia.twosecURL))

      #expect(
        player.sessionGeneration > before,
        "a media change from outside load(_:) left the generation stale, so recast cannot see it was superseded"
      )
    }

    /// The half that makes the fix safe rather than merely present. `load(_:)`
    /// advances the generation itself, and libVLC then reports the same change
    /// back as `.mediaChanged`. Advancing again on that echo would supersede a
    /// recast started in between, for a change it had already accounted for.
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

    /// Two different media in a row each advance it once, so the guard still
    /// discriminates after the de-duplication above.
    @Test
    func `Successive distinct media each advance it once`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let first = player.sessionGeneration
      player._handleEventForTesting(.mediaChanged)
      #expect(player.sessionGeneration == first)

      try player.adoptMediaForTesting(Media(url: TestMedia.twosecURL))
      let second = player.sessionGeneration
      #expect(second > first)
      player._handleEventForTesting(.mediaChanged)
      #expect(player.sessionGeneration == second, "the second echo advanced it again")
    }
  }
}
