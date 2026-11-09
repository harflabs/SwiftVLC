@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

extension Integration {
  /// CoreAudio reported its timing to the clock once a second. After a rate
  /// change became audible, the audio master clock kept extrapolating the
  /// previous rate until the next report, then stepped back and stalled video
  /// for up to a second on every slow-down (patch 0064).
  @Suite(.serialized, .timeLimit(.minutes(2)))
  @MainActor struct RateChangePlaybackTests {
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1"
          && TestCondition.canPlayMedia,
        "Requires the rebuilt release XCFramework and an audio device"
      )
    )
    func `rate changes do not stall video`() async throws {
      // The real audio output is under test; keep it nearly silent.
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--no-hw-dec", "--quiet", "--gain=0.01"
      ])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        let url = try #require(Bundle.module.url(
          forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"
        ))
        try player.load(Media(url: url))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        try #require(await poll(timeout: .seconds(10)) { (sink.latest?.frame ?? 0) >= 60 })
        for rate: Float in [2, 1, 0.5, 1] {
          let start = Date.timeIntervalSinceReferenceDate
          try player.setPlaybackRate(PlaybackRate(rate))
          // Audio already rendered at the previous rate plays out first.
          try await Task.sleep(for: .seconds(3))
          let shown = sink.samples.withLock { $0.filter { $0.wall >= start } }
          // The barcode advances at 30 frames per second of content.
          let settled = shown.filter { $0.wall >= start + 2 }
          let first = try #require(settled.first)
          let last = try #require(settled.last)
          let speed = Double(last.frame - first.frame) / 30 / (last.wall - first.wall)
          #expect(abs(speed - Double(rate)) < 0.2 * Double(rate), "\(rate)x played at \(speed)x")
          // Measured from each frame's first appearance: redisplays repeat it.
          var longestHold = 0.0
          var current = try #require(shown.first)
          for sample in shown where sample.frame != current.frame {
            longestHold = max(longestHold, sample.wall - current.wall)
            current = sample
          }
          #expect(longestHold < 0.2, "\(rate)x held a frame for \(longestHold) s")
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }
}
