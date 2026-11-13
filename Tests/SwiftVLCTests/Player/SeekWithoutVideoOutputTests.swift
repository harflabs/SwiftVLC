@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Integration {
  /// A selected video track whose output libVLC abandoned (playback started
  /// with no view) never submits a picture. Seeks that waited for one timed
  /// out after two seconds on every request, with the published time frozen.
  @Suite(.tags(.mainActor, .async, .media), .timeLimit(.minutes(1)))
  @MainActor struct SeekWithoutVideoOutputTests {
    @Test(
      .enabled(if: TestCondition.canPlayMedia, "Requires a window server so the display open fails")
    )
    func `seeks settle while video has no output`() async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"
      ))
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--quiet"]
      )
      let player = Player(instance: instance)
      do {
        try player.play(url: fixtureURL)
        try #require(await poll(timeout: .seconds(5)) {
          player.state == .playing && player.isSeekable && player.currentTime > .milliseconds(300)
        })
        try #require(
          player.activeVideoOutputs == 0 && player.videoTracks.contains { $0.isSelected },
          "precondition: a selected video track without an output"
        )

        for target: Int64 in [20000, 10000] {
          let clock = ContinuousClock()
          let start = clock.now
          let request = try player.requestSeek(to: .milliseconds(target))
          #expect(await request.outcome == .settled)
          #expect(clock.now - start < .seconds(1))
          #expect(abs(libvlc_media_player_get_time(player.pointer) - target) < 1500)
        }

        player.pause()
        try #require(await poll(timeout: .seconds(3)) { player.state == .paused })
        for target: Int64 in [30000, 5000] {
          let request = try player.requestSeek(to: .milliseconds(target))
          #expect(await request.outcome == .settled)
          #expect(player.activeNativeSeek == nil && player.queuedNativeSeek == nil)
          let publishedMilliseconds = Int64(player.currentTime / .milliseconds(1))
          #expect(abs(publishedMilliseconds - target) < 500)
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }
}
