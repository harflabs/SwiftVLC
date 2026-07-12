@testable import SwiftVLC
import CLibVLC
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

    /// Root-cause proof at the pinned C API boundary: two native list players
    /// retain the same media-player pointer, and stopping either list player
    /// sends `stop_async` to that shared handle. The Swift regression below
    /// proves a retiring wrapper no longer makes this call after its successor
    /// adopts the handle.
    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Pinned libVLC stop on either list wrapper disrupts their shared player`() async throws {
      let instance = TestInstance.makePlayback()
      let player = Player(instance: instance)
      defer { withExtendedLifetime(player) {} }
      let oldWrapper = try #require(libvlc_media_list_player_new(instance.pointer))
      let successor = try #require(libvlc_media_list_player_new(instance.pointer))
      defer {
        libvlc_media_list_player_stop_async(successor)
        libvlc_media_list_player_stop_async(oldWrapper)
        libvlc_media_list_player_release(successor)
        libvlc_media_list_player_release(oldWrapper)
      }
      libvlc_media_list_player_set_media_player(oldWrapper, player.pointer)
      libvlc_media_list_player_set_media_player(successor, player.pointer)
      let list = MediaList()
      try list.append(Media(url: TestMedia.sparseURL))
      libvlc_media_list_player_set_media_list(oldWrapper, list.pointer)
      libvlc_media_list_player_play(oldWrapper)
      try #require(
        await poll { player.nativePlaybackState == .playing },
        "Waiting for: shared native player starts"
      )

      let terminalTransition = subscribeAndAwaitTerminalStop(on: player)
      libvlc_media_list_player_stop_async(oldWrapper)

      try await requireReached(
        terminalTransition,
        "Pinned libVLC emitted no stopping transition for the shared handle"
      )
    }

    /// Rebuilding only the list wrapper must not stop the shared native
    /// media-player handle. This is the handle an active PiP session also
    /// observes, so an old list wrapper stopping it tears down PiP playback.
    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Clearing mediaList while playing preserves the shared player`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      let list = MediaList()
      try list.append(Media(url: TestMedia.sparseURL))
      listPlayer.mediaPlayer = player
      listPlayer.mediaList = list
      listPlayer.play()
      defer { listPlayer.stop() }
      let retiringWrapper = try #require(libvlc_media_list_player_retain(listPlayer.pointer))
      defer {
        libvlc_media_list_player_stop_async(retiringWrapper)
        libvlc_media_list_player_release(retiringWrapper)
      }

      try #require(
        await poll(until: { player.nativePlaybackState == .playing }),
        "Waiting for: shared player reaches playing"
      )

      listPlayer.mediaList = nil

      // Keep the retired wrapper alive past its queued Swift release and prove
      // it was synchronously severed from the shared player. This closes the
      // list-end race: even if its old playlist callback advances now, it can
      // only drive the independent neutral player.
      let retiredBinding = try #require(
        libvlc_media_list_player_get_media_player(retiringWrapper)
      )
      defer { libvlc_media_player_release(retiredBinding) }
      let successorBinding = try #require(
        libvlc_media_list_player_get_media_player(listPlayer.pointer)
      )
      defer { libvlc_media_player_release(successorBinding) }
      #expect(retiredBinding != player.pointer)
      #expect(successorBinding == player.pointer)
      let sharedMediaBeforeRetiredControl = try #require(
        libvlc_media_player_get_media(player.pointer)
      )
      defer { libvlc_media_release(sharedMediaBeforeRetiredControl) }
      libvlc_media_list_player_play(retiringWrapper)
      let sharedMediaAfterRetiredControl = try #require(
        libvlc_media_player_get_media(player.pointer)
      )
      defer { libvlc_media_release(sharedMediaAfterRetiredControl) }
      #expect(sharedMediaAfterRetiredControl == sharedMediaBeforeRetiredControl)

      let oldWrapperStoppedSharedPlayer = try await poll(
        timeout: .seconds(2),
        until: { player.nativePlaybackState == .stopped }
      )
      #expect(
        oldWrapperStoppedSharedPlayer == false,
        "retired list wrapper stopped the shared player adopted by its replacement"
      )
      #expect(listPlayer.isPlaying)
    }

    @Test
    func `Rebuild transfers counted ownership before returning`() {
      let instance = TestInstance.makeAudioOnly()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      let lifetime = player.nativeHandleLifetime
      let list = MediaList()

      listPlayer.mediaPlayer = player
      #expect(lifetime.nativeOwnerCount == 2)
      listPlayer.mediaList = list
      listPlayer.mediaList = nil

      // The retiring wrapper itself releases off-main, but its binding to the
      // shared player is synchronously replaced with a neutral player.
      #expect(lifetime.nativeOwnerCount == 2)
      #expect(!lifetime.isReleased)

      listPlayer.mediaPlayer = nil
      #expect(lifetime.nativeOwnerCount == 1)
      #expect(!lifetime.isReleased)
    }

    @Test
    func `Attaching a player to a second list transfers sole live ownership`() {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let first = MediaListPlayer(instance: instance)
      let second = MediaListPlayer(instance: instance)
      let lifetime = player.nativeHandleLifetime

      first.mediaPlayer = player
      second.mediaPlayer = player

      #expect(first.mediaPlayer == nil)
      #expect(second.mediaPlayer === player)
      #expect(player.attachedMediaListPlayer === second)
      #expect(lifetime.nativeOwnerCount == 2)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Transferring an actively playing shared player does not stop it`() async throws {
      let instance = TestInstance.makePlayback()
      let player = Player(instance: instance)
      let first = MediaListPlayer(instance: instance)
      let second = MediaListPlayer(instance: instance)
      let list = MediaList()
      try list.append(Media(url: TestMedia.sparseURL))
      first.mediaPlayer = player
      first.mediaList = list
      first.play()
      defer { second.stop() }
      let retiringFirstWrapper = try #require(libvlc_media_list_player_retain(first.pointer))
      defer {
        libvlc_media_list_player_stop_async(retiringFirstWrapper)
        libvlc_media_list_player_release(retiringFirstWrapper)
      }
      try #require(
        await poll { player.nativePlaybackState == .playing },
        "Waiting for: first list starts the shared player"
      )

      second.mediaPlayer = player

      let retiredBinding = try #require(
        libvlc_media_list_player_get_media_player(retiringFirstWrapper)
      )
      defer { libvlc_media_player_release(retiredBinding) }
      #expect(retiredBinding != player.pointer)

      let retiredOwnerStoppedSharedPlayer = try await poll(
        timeout: .seconds(2),
        until: { player.nativePlaybackState == .stopped }
      )
      #expect(!retiredOwnerStoppedSharedPlayer)
      #expect(first.mediaPlayer == nil)
      #expect(second.mediaPlayer === player)
      #expect(player.attachedMediaListPlayer === second)
    }

    @Test(.timeLimit(.minutes(1)))
    func `List-player deinit ends its counted native owner after release`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let lifetime = player.nativeHandleLifetime
      var listPlayer: MediaListPlayer? = MediaListPlayer(instance: instance)
      listPlayer?.mediaPlayer = player
      #expect(lifetime.nativeOwnerCount == 2)

      listPlayer = nil

      try #require(
        await poll { lifetime.nativeOwnerCount == 1 },
        "Waiting for: deinitialized list player's native release"
      )
      #expect(!lifetime.isReleased)
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

    @Test
    func `play at negative index rejects before reaching libVLC`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)

      #expect(throws: VLCError.invalidInput("index must be non-negative")) {
        try listPlayer.play(at: -1)
      }
    }

    @Test
    func `play at valid attached index reaches libVLC and can be stopped`() throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      defer { listPlayer.stop() }

      try listPlayer.play(at: 0)
    }

    @Test
    func `play attached media item reaches libVLC and can be stopped`() throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let list = MediaList()
      let media = try Media(url: TestMedia.twosecURL)
      try list.append(media)
      listPlayer.mediaList = list
      defer { listPlayer.stop() }

      try listPlayer.play(media)
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
