@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// `load(_:)` replaces the media and waits for `play()`. libVLC, handed new
/// media on a player it is already running, starts that media by itself, so
/// a player with no video view (the only case that reused the running
/// handle) played what was merely loaded.
extension Integration {
  @Suite(
    .tags(.mainActor, .async, .media),
    .serialized,
    .enabled(if: TestCondition.canPlayMedia, "Requires real playback")
  )
  @MainActor struct PlayerLoadDuringPlaybackTests {
    @Test(.timeLimit(.minutes(1)), arguments: [["--no-video", "--aout=dummy", "--quiet"], ["--vout=dummy", "--aout=dummy", "--quiet"]])
    func `Loading during playback does not start the new media`(arguments: [String]) async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let player = try Player(instance: VLCInstance(arguments: arguments))
      do {
        try player.play(url: fixtureURL)
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && player.currentTime >= .milliseconds(400)
          },
          "Waiting for the first media to play"
        )

        let loaded = try Media(url: fixtureURL)
        let loadedPointer = loaded.pointer
        player.load(loaded)
        #expect(player.state == .idle)
        #expect(!player.isPlaybackRequestedActive)

        try await Task.sleep(for: .seconds(2))
        #expect(player.state == .idle, "loaded media reached \(player.state) without play()")
        #expect(player.currentTime == .zero)
        #expect(!player.isPlaybackRequestedActive)
        #expect(!libvlc_media_player_is_playing(player.pointer), "libVLC is playing media that was only loaded")

        try player.play()
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && player.currentTime >= .milliseconds(300)
          },
          "Waiting for the loaded media to play once asked"
        )
        #expect(player.currentMedia?.pointer == loadedPointer)
        #expect(player.currentTime < .seconds(5))
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }

    /// The window before libVLC has reported anything for a start it already
    /// accepted: its state still reads stopped, but the input is running.
    @Test(.timeLimit(.minutes(1)))
    func `Loading right after play does not start the new media`() async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let player = try Player(instance: VLCInstance(arguments: ["--no-video", "--aout=dummy", "--quiet"]))
      do {
        try player.play(url: fixtureURL)
        player.load(try Media(url: fixtureURL))

        try await Task.sleep(for: .seconds(2))
        #expect(player.state == .idle, "loaded media reached \(player.state) without play()")
        #expect(player.currentTime == .zero)
        #expect(!libvlc_media_player_is_playing(player.pointer))
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }
}
