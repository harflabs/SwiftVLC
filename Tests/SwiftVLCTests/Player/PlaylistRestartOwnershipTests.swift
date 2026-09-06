@testable import SwiftVLC
import CLibVLC
import Foundation
import Observation
import Testing

extension Integration {
  @Suite(.tags(.mainActor), .timeLimit(.minutes(1)))
  @MainActor struct PlaylistRestartOwnershipTests {
    @Test(arguments: ["play", "index", "media", "next", "previous", "resume", "toggle"])
    func `Playlist transport prepares and rebinds a stopped drawable handle`(_ command: String) async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let media = try Media(url: TestMedia.silenceURL)
      player.load(media)
      let list = MediaList()
      try list.append(media)
      let playlist = MediaListPlayer(instance: instance)
      playlist.mediaList = list
      playlist.mediaPlayer = player
      player.setDrawable(NSObject())
      var starts = 0
      playlist._nativeTransportDispatchOverrideForTesting = { command in
        if case .stop = command {} else {
          starts += 1
        }
        return 0
      }
      playlist.play()
      playlist.stop()
      let outgoing = player.pointer
      try #require(player.nativePlayerNeedsReplacementBeforePlayback)
      switch command {
      case "play": playlist.play()
      case "index": try playlist.play(at: 0)
      case "media": try playlist.play(media)
      case "next": try playlist.next()
      case "previous": try playlist.previous()
      case "resume": playlist.resume()
      default: playlist.togglePause()
      }
      #expect(starts == 2)
      #expect(player.pointer != outgoing)
      #expect(!player.nativePlayerNeedsReplacementBeforePlayback)
      let bound = try #require(libvlc_media_list_player_get_media_player(playlist.pointer))
      #expect(bound == player.pointer)
      libvlc_media_player_release(bound)
      playlist.mediaPlayer = nil
      await player.shutdown()
    }

    @Test
    func `An ownership change during preparation supersedes the older playlist command`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let takeover = Player(instance: instance)
      let list = MediaList()
      try list.append(Media(url: TestMedia.silenceURL))
      let playlist = MediaListPlayer(instance: instance)
      playlist.mediaList = list
      playlist.mediaPlayer = player
      player.setDrawable(NSObject())
      var starts = 0
      playlist._nativeTransportDispatchOverrideForTesting = { command in
        if case .play = command {
          starts += 1
        }
        return 0
      }
      playlist.play()
      playlist.stop()
      player.activeVideoOutputs = 1
      withObservationTracking { _ = player.activeVideoOutputs } onChange: {
        MainActor.assumeIsolated { playlist.mediaPlayer = takeover }
      }
      playlist.play()
      #expect(playlist.mediaPlayer === takeover)
      #expect(starts == 1)
      playlist.mediaPlayer = nil
      await player.shutdown()
      await takeover.shutdown()
    }

    @Test
    func `Failed playlist preparation can retry without dispatching the rejected candidate`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let list = MediaList()
      try list.append(Media(url: TestMedia.silenceURL))
      let playlist = MediaListPlayer(instance: instance)
      playlist.mediaList = list
      playlist.mediaPlayer = player
      player.setDrawable(NSObject())
      var starts = 0
      playlist._nativeTransportDispatchOverrideForTesting = { command in
        if case .play = command {
          starts += 1
        }
        return 0
      }
      playlist.play()
      playlist.stop()
      let outgoing = player.pointer
      player.eventBridge._forcePreparedAttachmentFailureForTesting(afterAttachedCount: 1)
      playlist.play()
      #expect(starts == 1)
      #expect(player.pointer == outgoing)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      player.eventBridge._forcePreparedAttachmentFailureForTesting(afterAttachedCount: nil)
      playlist.play()
      #expect(starts == 2)
      playlist.mediaPlayer = nil
      await player.shutdown()
    }
  }
}
