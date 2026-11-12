@testable import SwiftVLC
import Foundation
import Testing

/// libVLC announces a new input's `Opening` and `Playing` only when they
/// change its player-wide state. When it swaps the input of a player that
/// never left the playing state (a list skip, or a `play()` that overtakes
/// the stop before it) it reports `MediaChanged` and nothing else, so the
/// state mirror has to be settled at that media change.
extension Integration {
  @Suite(
    .tags(.mainActor, .async, .media),
    .serialized,
    .enabled(if: TestCondition.canPlayMedia, "Requires real playback")
  )
  @MainActor struct PlayerSameHandleMediaChangeStateTests {
    private func makeList(count: Int) throws -> MediaList {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let list = MediaList()
      for _ in 0..<count {
        try list.append(Media(url: fixtureURL))
      }
      return list
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func `Skipping in a playing list keeps the player state playing`(forward: Bool) async throws {
      let instance = TestInstance.makePlayback()
      let player = Player(instance: instance)
      let listPlayer = MediaListPlayer(instance: instance)
      listPlayer.mediaPlayer = player
      listPlayer.mediaList = try makeList(count: 3)
      do {
        try listPlayer.play(at: 1)
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && player.currentTime >= .milliseconds(500)
          },
          "Waiting for the middle item to play"
        )

        let generation = player.generation
        if forward {
          try listPlayer.next()
        } else {
          try listPlayer.previous()
        }
        try #require(
          await poll(timeout: .seconds(5)) { player.generation > generation },
          "Waiting for the skipped-to item to be adopted"
        )
        #expect(
          try await poll(timeout: .seconds(3)) {
            player.state == .playing && player.currentTime >= .milliseconds(300)
          },
          "state is \(player.state) while the skipped-to item plays"
        )
        #expect(player.isPlaybackRequestedActive)
      } catch {
        listPlayer.mediaPlayer = nil
        await player.shutdown()
        throw error
      }
      listPlayer.mediaPlayer = nil
      await player.shutdown()
    }

    /// `stop()` followed at once by `play()` restarts the media. Whether
    /// libVLC reports the restart as state events depends on which of the two
    /// its teardown thread sees first, so the idiom is repeated.
    @Test(.timeLimit(.minutes(2)))
    func `Stop then play at once ends in the playing state`() async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let instance = try VLCInstance(arguments: ["--no-video", "--aout=dummy", "--quiet"])
      let player = Player(instance: instance)
      do {
        try player.play(url: fixtureURL)
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && player.currentTime >= .milliseconds(400)
          },
          "Waiting for playback to start"
        )

        for restart in 0..<20 {
          let generation = player.generation
          player.stop()
          try player.play()
          try #require(
            await poll(timeout: .seconds(5)) { player.generation > generation },
            "Waiting for restart \(restart) to begin a new session"
          )
          try #require(
            await poll(timeout: .seconds(3)) {
              player.state == .playing && player.currentTime >= .milliseconds(200)
            },
            "restart \(restart): state is \(player.state) at \(player.currentTime) with native \(player.nativePlaybackState)"
          )
          #expect(player.isPlaybackRequestedActive)
        }

        // The mirror must be usable, not merely readable: a pause has to land.
        player.pause()
        #expect(try await poll(timeout: .seconds(3)) { player.state == .paused })
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }
}
