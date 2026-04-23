@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct MediaListPlayerExtendedTests {
    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Play specific item at index from list`() async throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      // Play the second item directly by index
      try listPlayer.play(at: 1)
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Mode switching during playback`() async throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      #expect(listPlayer.playbackMode == .default)
      listPlayer.play()
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      // Switch to loop mode while playing
      listPlayer.playbackMode = .loop
      #expect(listPlayer.playbackMode == .loop)
      // Switch to repeat mode while playing
      listPlayer.playbackMode = .repeat
      #expect(listPlayer.playbackMode == .repeat)
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Toggle pause during playback`() async throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      // Toggle pause — should pause
      listPlayer.togglePause()
      try await Task.sleep(for: .milliseconds(150))
      // Toggle pause again — should resume
      listPlayer.togglePause()
      try await Task.sleep(for: .milliseconds(150))
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Replace mediaList while playing`() async throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list1 = MediaList()
      try list1.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list1
      listPlayer.play()
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      // Replace the list while playing
      let list2 = MediaList()
      try list2.append(Media(url: TestMedia.testMP4URL))
      listPlayer.mediaList = list2
      #expect(listPlayer.mediaList != nil)
      listPlayer.stop()
    }

    @Test
    func `Replace mediaPlayer while configured`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player1 = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player1
      #expect(listPlayer.mediaPlayer != nil)
      // Replace with a different player
      let player2 = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player2
      #expect(listPlayer.mediaPlayer != nil)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Play from beginning after stop`() async throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      // First play cycle
      listPlayer.play()
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      listPlayer.stop()
      try #require(await poll(until: { !listPlayer.isPlaying }), "Waiting for: !listPlayer.isPlaying")
      // Second play cycle — should start from beginning
      listPlayer.play()
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `State reflects paused during pause`() async throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()
      guard try await poll(until: { listPlayer.isPlaying }) else {
        listPlayer.stop()
        return
      }
      listPlayer.pause()
      guard try await poll(until: { listPlayer.state == .paused }) else {
        listPlayer.stop()
        return
      }
      listPlayer.stop()
    }

    @Test
    func `Multiple stop calls don't crash`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      listPlayer.mediaList = list
      // Call stop multiple times in succession
      listPlayer.stop()
      listPlayer.stop()
      listPlayer.stop()
      // No crash = success
    }
  }
}
