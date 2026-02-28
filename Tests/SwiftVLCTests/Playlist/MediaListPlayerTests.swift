@testable import SwiftVLC
import Testing

@Suite("MediaListPlayer", .tags(.integration, .mainActor), .serialized)
@MainActor
struct MediaListPlayerTests {
  @Test("Init succeeds")
  func initSucceeds() throws {
    let listPlayer = try MediaListPlayer()
    _ = listPlayer
  }

  @Test("MediaPlayer get and set")
  func mediaPlayerGetSet() throws {
    let listPlayer = try MediaListPlayer()
    #expect(listPlayer.mediaPlayer == nil)
    let player = try Player()
    listPlayer.mediaPlayer = player
    #expect(listPlayer.mediaPlayer != nil)
  }

  @Test("MediaList get and set")
  func mediaListGetSet() throws {
    let listPlayer = try MediaListPlayer()
    #expect(listPlayer.mediaList == nil)
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(listPlayer.mediaList != nil)
  }

  @Test(
    "Playback mode get and set",
    arguments: [PlaybackMode.default, .loop, .repeat]
  )
  func playbackModeGetSet(mode: PlaybackMode) throws {
    let listPlayer = try MediaListPlayer()
    listPlayer.playbackMode = mode
    #expect(listPlayer.playbackMode == mode)
  }

  @Test("Play without list doesn't crash")
  func playWithoutList() throws {
    let listPlayer = try MediaListPlayer()
    listPlayer.play()
    listPlayer.stop()
  }

  @Test("Pause without playback doesn't crash")
  func pauseWithoutPlayback() throws {
    let listPlayer = try MediaListPlayer()
    listPlayer.pause()
  }

  @Test("Resume without playback doesn't crash")
  func resumeWithoutPlayback() throws {
    let listPlayer = try MediaListPlayer()
    listPlayer.resume()
  }

  @Test("Stop without playback doesn't crash")
  func stopWithoutPlayback() throws {
    let listPlayer = try MediaListPlayer()
    listPlayer.stop()
  }

  @Test("Play at invalid index throws")
  func playAtInvalidIndex() throws {
    let listPlayer = try MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(throws: VLCError.self) {
      try listPlayer.play(at: 0)
    }
  }

  @Test("Next without items throws")
  func nextWithoutItemsThrows() throws {
    let listPlayer = try MediaListPlayer()
    #expect(throws: VLCError.self) {
      try listPlayer.next()
    }
  }

  @Test("Previous without items throws")
  func previousWithoutItemsThrows() throws {
    let listPlayer = try MediaListPlayer()
    #expect(throws: VLCError.self) {
      try listPlayer.previous()
    }
  }

  @Test("State property")
  func stateProperty() throws {
    let listPlayer = try MediaListPlayer()
    _ = listPlayer.state
  }

  @Test("isPlaying property")
  func isPlayingProperty() throws {
    let listPlayer = try MediaListPlayer()
    #expect(listPlayer.isPlaying == false)
  }

  @Test("Toggle pause doesn't crash")
  func togglePause() throws {
    let listPlayer = try MediaListPlayer()
    listPlayer.togglePause()
  }

  @Test("Play at valid index", .tags(.async, .media), .enabled(if: TestCondition.canPlayMedia))
  func playAtValidIndex() async throws {
    let listPlayer = try MediaListPlayer()
    let player = try Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    listPlayer.mediaList = list
    try listPlayer.play(at: 0)
    try await Task.sleep(for: .milliseconds(300))
    listPlayer.stop()
  }

  @Test("Play media item not in list throws")
  func playMediaNotInListThrows() throws {
    let listPlayer = try MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    let media = try Media(url: TestMedia.testMP4URL)
    #expect(throws: VLCError.self) {
      try listPlayer.play(media)
    }
  }

  @Test("Next at end of list throws")
  func nextAtEndThrows() throws {
    let listPlayer = try MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(throws: VLCError.self) {
      try listPlayer.next()
    }
  }

  @Test("Previous at start of list throws")
  func previousAtStartThrows() throws {
    let listPlayer = try MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(throws: VLCError.self) {
      try listPlayer.previous()
    }
  }

  @Test("Play and stop lifecycle", .tags(.async, .media), .enabled(if: TestCondition.canPlayMedia))
  func playAndStopLifecycle() async throws {
    let listPlayer = try MediaListPlayer()
    let player = try Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.play()
    try await Task.sleep(for: .milliseconds(500))
    #expect(listPlayer.isPlaying)
    listPlayer.stop()
    try await Task.sleep(for: .milliseconds(200))
  }

  @Test("Pause and resume lifecycle", .tags(.async, .media), .enabled(if: TestCondition.canPlayMedia))
  func pauseAndResumeLifecycle() async throws {
    let listPlayer = try MediaListPlayer()
    let player = try Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.play()
    try await Task.sleep(for: .milliseconds(500))
    listPlayer.pause()
    try await Task.sleep(for: .milliseconds(100))
    listPlayer.resume()
    try await Task.sleep(for: .milliseconds(100))
    listPlayer.stop()
  }

  @Test("State during playback", .tags(.async, .media), .enabled(if: TestCondition.canPlayMedia))
  func stateDuringPlayback() async throws {
    let listPlayer = try MediaListPlayer()
    let player = try Player()
    listPlayer.mediaPlayer = player
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))
    listPlayer.mediaList = list
    listPlayer.play()
    try await Task.sleep(for: .milliseconds(500))
    let state = listPlayer.state
    // Should be playing
    #expect(state == .playing)
    listPlayer.stop()
  }

  @Test("Set media player to nil")
  func setMediaPlayerToNil() throws {
    let listPlayer = try MediaListPlayer()
    let player = try Player()
    listPlayer.mediaPlayer = player
    #expect(listPlayer.mediaPlayer != nil)
    listPlayer.mediaPlayer = nil
    #expect(listPlayer.mediaPlayer == nil)
  }

  @Test("Set media list to nil")
  func setMediaListToNil() throws {
    let listPlayer = try MediaListPlayer()
    let list = MediaList()
    listPlayer.mediaList = list
    #expect(listPlayer.mediaList != nil)
    listPlayer.mediaList = nil
    #expect(listPlayer.mediaList == nil)
  }
}
