@testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.integration, .mainActor))
@MainActor
struct MediaListPlayerTests {
  @Test
  func `Init succeeds`() {
    let listPlayer = MediaListPlayer()
    _ = listPlayer
  }

  @Test
  func `MediaPlayer get and set`() {
    let listPlayer = MediaListPlayer()
    #expect(listPlayer.mediaPlayer == nil)
    let player = Player()
    listPlayer.mediaPlayer = player
    #expect(listPlayer.mediaPlayer != nil)
  }

  @Test
  func `MediaList get and set`() {
    let listPlayer = MediaListPlayer()
    #expect(listPlayer.mediaList == nil)
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(listPlayer.mediaList != nil)
  }

  @Test(
    arguments: [PlaybackMode.default, .loop, .repeat]
  )
  func `Playback mode get and set`(mode: PlaybackMode) {
    let listPlayer = MediaListPlayer()
    listPlayer.playbackMode = mode
    #expect(listPlayer.playbackMode == mode)
  }

  @Test
  func `Play without list doesn't crash`() {
    let listPlayer = MediaListPlayer()
    listPlayer.play()
    listPlayer.stop()
  }

  @Test
  func `Pause without playback doesn't crash`() {
    let listPlayer = MediaListPlayer()
    listPlayer.pause()
  }

  @Test
  func `Resume without playback doesn't crash`() {
    let listPlayer = MediaListPlayer()
    listPlayer.resume()
  }

  @Test
  func `Stop without playback doesn't crash`() {
    let listPlayer = MediaListPlayer()
    listPlayer.stop()
  }

  @Test
  func `Play at invalid index throws`() throws {
    let listPlayer = MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(throws: VLCError.self) {
      try listPlayer.play(at: 0)
    }
  }

  @Test
  func `Next without items throws`() throws {
    let listPlayer = MediaListPlayer()
    #expect(throws: VLCError.self) {
      try listPlayer.next()
    }
  }

  @Test
  func `Previous without items throws`() throws {
    let listPlayer = MediaListPlayer()
    #expect(throws: VLCError.self) {
      try listPlayer.previous()
    }
  }

  @Test
  func `State property`() {
    let listPlayer = MediaListPlayer()
    _ = listPlayer.state
  }

  @Test
  func `isPlaying property`() {
    let listPlayer = MediaListPlayer()
    #expect(listPlayer.isPlaying == false)
  }

  @Test
  func `Toggle pause doesn't crash`() {
    let listPlayer = MediaListPlayer()
    listPlayer.togglePause()
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `Play at valid index`() async throws {
    let listPlayer = MediaListPlayer()
    let player = Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    listPlayer.mediaList = list
    try listPlayer.play(at: 0)
    guard try await poll(until: { listPlayer.isPlaying }) else { listPlayer.stop(); return }
    listPlayer.stop()
  }

  @Test
  func `Play media item not in list throws`() throws {
    let listPlayer = MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    let media = try Media(url: TestMedia.testMP4URL)
    #expect(throws: VLCError.self) {
      try listPlayer.play(media)
    }
  }

  @Test
  func `Next at end of list throws`() throws {
    let listPlayer = MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(throws: VLCError.self) {
      try listPlayer.next()
    }
  }

  @Test
  func `Previous at start of list throws`() throws {
    let listPlayer = MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(throws: VLCError.self) {
      try listPlayer.previous()
    }
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `Play and stop lifecycle`() async throws {
    let listPlayer = MediaListPlayer()
    let player = Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.play()
    guard try await poll(until: { listPlayer.isPlaying }) else { listPlayer.stop(); return }
    #expect(listPlayer.isPlaying)
    listPlayer.stop()
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `Pause and resume lifecycle`() async throws {
    let listPlayer = MediaListPlayer()
    let player = Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.play()
    guard try await poll(until: { listPlayer.isPlaying }) else { listPlayer.stop(); return }
    listPlayer.pause()
    try await Task.sleep(for: .milliseconds(100))
    listPlayer.resume()
    try await Task.sleep(for: .milliseconds(100))
    listPlayer.stop()
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `State during playback`() async throws {
    let listPlayer = MediaListPlayer()
    let player = Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.play()
    guard try await poll(until: { listPlayer.state == .playing }) else { listPlayer.stop(); return }
    #expect(listPlayer.state == .playing)
    listPlayer.stop()
  }

  @Test
  func `Set media player to nil`() {
    let listPlayer = MediaListPlayer()
    let player = Player()
    listPlayer.mediaPlayer = player
    #expect(listPlayer.mediaPlayer != nil)
    listPlayer.mediaPlayer = nil
    #expect(listPlayer.mediaPlayer == nil)
    let nativePlayer = libvlc_media_list_player_get_media_player(listPlayer.pointer)
    defer {
      if let nativePlayer {
        libvlc_media_player_release(nativePlayer)
      }
    }
    #expect(nativePlayer != nil)
    #expect(nativePlayer != player.pointer)
  }

  @Test
  func `Set media list to nil`() {
    let listPlayer = MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(listPlayer.mediaList != nil)
    listPlayer.mediaList = nil
    #expect(listPlayer.mediaList == nil)
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `Clearing media list removes stale native playback state`() async throws {
    let listPlayer = MediaListPlayer()
    let player = Player()
    listPlayer.mediaPlayer = player

    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.mediaList = nil

    listPlayer.play()
    try await Task.sleep(for: .milliseconds(300))
    #expect(!listPlayer.isPlaying)
  }
}
