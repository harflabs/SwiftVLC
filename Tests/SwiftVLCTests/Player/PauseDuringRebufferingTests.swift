@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  /// libVLC defers a pause requested while it rebuffers (after a seek or a
  /// late network stream) and applies it once buffering ends. A resume that
  /// arrives first cancels the deferred pause without any state event, so the
  /// wrapper never hears a `.paused` for the pause it issued.
  @Suite(
    .tags(.mainActor, .async, .media),
    .serialized,
    .enabled(
      if: TestCondition.canPlayMedia
        || ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1",
      "Requires real playback"
    )
  )
  @MainActor struct PauseDuringRebufferingTests {
    /// Paced slightly above the fixture's 30 kB/s mux rate, so refilling the
    /// network cache after a seek takes about as long as the cache is deep.
    private static let chunkDelayMicroseconds: UInt32 = 110_000

    @Test(.timeLimit(.minutes(2)))
    func `A pause undone while libVLC rebuffers does not block later pauses`() async throws {
      let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Showcase/UITests/iOS/Fixtures/test.mp4")
      let server = try MP4RangeProbeServer(
        resources: ["/seek-fixture.mp4": Data(contentsOf: fixtureURL)],
        path: "/seek-fixture.mp4",
        chunkDelayMicroseconds: Self.chunkDelayMicroseconds
      )
      defer { server.stop() }

      let instance = try VLCInstance(arguments: [
        "--vout=dummy", "--aout=dummy", "--quiet", "--network-caching=4000"
      ])
      let player = Player(instance: instance)
      do {
        try player.play(url: server.url)
        try #require(
          await poll(timeout: .seconds(20)) {
            player.state == .playing && player.isSeekable && player.currentTime >= .seconds(1)
          },
          "Waiting for paced HTTP playback to start"
        )

        try player.seek(to: .seconds(30))
        // Inside the window where libVLC refills its cache for the new position.
        try await Task.sleep(for: .milliseconds(600))
        player.pause()
        try #require(
          player.pauseTransition == .pausing,
          "precondition: the pause must have reached libVLC"
        )
        try await Task.sleep(for: .milliseconds(300))
        try #require(
          player.state == .playing,
          "precondition: libVLC must still be holding the pause for the end of buffering"
        )
        player.resume()

        let resumedAt = player.currentTime
        try #require(
          await poll(timeout: .seconds(20)) {
            player.state == .playing && player.currentTime >= resumedAt + .seconds(2)
          },
          "Waiting for playback to continue after the undone pause"
        )
        #expect(player.isPlaybackRequestedActive)

        player.pause()
        #expect(
          try await poll(timeout: .seconds(5)) { player.state == .paused },
          "a later pause never reached libVLC"
        )
        #expect(!player.isPlaybackRequestedActive)
        let pausedTime = player.currentTime
        try await Task.sleep(for: .seconds(1))
        #expect(player.currentTime == pausedTime, "playback kept running after pause()")
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }
}
