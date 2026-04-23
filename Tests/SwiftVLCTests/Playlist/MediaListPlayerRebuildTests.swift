@testable import SwiftVLC
import Foundation
import Testing

/// Covers `MediaListPlayer.rebuildNativePlayer` — the path where the
/// caller clears `mediaPlayer` or `mediaList` to nil. Because libVLC
/// cannot "unset" a player or list once bound, the wrapper rebuilds
/// the native media-list-player instance with the remaining
/// configuration preserved.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct MediaListPlayerRebuildTests {
    /// Clearing `mediaPlayer` triggers a native rebuild. The new
    /// instance must preserve the playback mode and any attached list.
    @Test
    func `Clearing mediaPlayer rebuilds and preserves playback mode`() throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))

      listPlayer.mediaPlayer = player
      listPlayer.mediaList = list
      listPlayer.playbackMode = .loop

      listPlayer.mediaPlayer = nil

      #expect(listPlayer.mediaPlayer == nil)
      #expect(listPlayer.playbackMode == .loop, "Playback mode must survive native rebuild")
      #expect(listPlayer.mediaList?.count == 1, "Media list must be re-attached to the rebuilt native player")
    }

    /// Clearing `mediaList` triggers the same rebuild path.
    @Test
    func `Clearing mediaList rebuilds and preserves mediaPlayer and mode`() throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))

      listPlayer.mediaPlayer = player
      listPlayer.mediaList = list
      listPlayer.playbackMode = .repeat

      listPlayer.mediaList = nil

      #expect(listPlayer.mediaList == nil)
      #expect(listPlayer.mediaPlayer === player, "Player must survive the rebuild")
      #expect(listPlayer.playbackMode == .repeat)
    }

    /// After a rebuild, re-attaching a mediaPlayer / mediaList must
    /// work without leaking or crashing.
    @Test
    func `Rebuild then re-attach works cleanly`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)

      listPlayer.mediaPlayer = player
      listPlayer.mediaPlayer = nil
      listPlayer.mediaPlayer = player

      #expect(listPlayer.mediaPlayer === player)
    }

    /// `next()` / `previous()` return non-zero from libVLC when there
    /// is no list context. Pin that behavior.
    @Test
    func `next and previous without a list throw`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try listPlayer.next()
      }
      #expect(throws: VLCError.self) {
        try listPlayer.previous()
      }
    }

    /// `togglePause` / `pause` / `resume` / `stop` are all safe no-ops
    /// on an empty list player.
    @Test
    func `Pause resume stop are safe without media`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      listPlayer.pause()
      listPlayer.resume()
      listPlayer.togglePause()
      listPlayer.stop()
      #expect(listPlayer.isPlaying == false)
    }
  }
}
