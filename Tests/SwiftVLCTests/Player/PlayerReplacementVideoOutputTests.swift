@testable import SwiftVLC
import Foundation
import Testing

/// Switching media during playback moves the player to a fresh native
/// handle. That handle must keep the instance's video output choice: a
/// player with no view attached has nothing else to render into.
extension Integration {
  @Suite(
    .tags(.mainActor, .async, .media),
    .serialized,
    .enabled(if: TestCondition.canPlayMedia, "Requires real playback")
  )
  @MainActor struct PlayerReplacementVideoOutputTests {
    @Test(.timeLimit(.minutes(1)))
    func `A media switch during playback keeps the instance video output`() async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let player = Player(instance: TestInstance.makePlayback())
      do {
        try player.play(url: fixtureURL)
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && player.activeVideoOutputs > 0
          },
          "precondition: the instance's dummy output must open on the first handle"
        )

        let nativeHandle = player.eventBridge.currentNativeHandleGeneration
        try player.play(url: fixtureURL)
        try #require(
          player.eventBridge.currentNativeHandleGeneration != nativeHandle,
          "precondition: the switch must have replaced the native handle"
        )
        #expect(
          try await poll(timeout: .seconds(5)) { player.activeVideoOutputs > 0 },
          "the replacement handle opened no video output"
        )
        try #require(
          await poll(timeout: .seconds(5)) { player.currentTime >= .milliseconds(500) }
        )
        #expect(player.playbackHealth.counters.presentedVideoFrames > 0)
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }
}
