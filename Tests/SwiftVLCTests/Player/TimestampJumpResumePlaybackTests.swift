@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

extension Integration {
  /// Pausing just before a timestamp discontinuity leaves pictures of the old
  /// timeline queued behind a newer clock context. Resume used to shift only
  /// the newest context, so those pictures converted late by the whole pause,
  /// were dropped, and the picture froze until the new timeline (patch 0055).
  @Suite(
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(
      if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1",
      "Requires native video output"
    )
  )
  @MainActor struct TimestampJumpResumePlaybackTests {
    @Test(arguments: [false, true])
    func `resume before a timestamp jump presents every queued frame`(audio: Bool) async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--aout=dummy", "--no-hw-dec", "--quiet", audio ? "--audio" : "--no-audio"
      ])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        // Barcode frames 0-359; PTS jumps by +3000 s at frame 120 and back at 240.
        let url = try #require(Bundle.module.url(
          forResource: "timestamp-jump", withExtension: "ts", subdirectory: "Fixtures/seek-oracle"
        ))
        try player.load(Media(url: url))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        for jump in [120, 240] {
          try #require(await poll(every: .milliseconds(5), timeout: .seconds(20)) {
            (sink.latest?.frame ?? 0) >= jump - 15
          })
          player.pause()
          try #require(await poll(timeout: .seconds(3)) { player.state == .paused })
          let pausedFrame = try #require(sink.latest?.frame)
          try await Task.sleep(for: .seconds(1))
          let resumeIndex = sink.count
          let resumedAt = Date.timeIntervalSinceReferenceDate
          player.resume()
          try #require(await poll(every: .milliseconds(10), timeout: .seconds(5)) {
            (sink.latest?.frame ?? 0) >= jump + 30
          })
          let shown = sink.samples.withLock { Array($0[resumeIndex...]) }
          let dropped = Set(pausedFrame + 1..<jump).subtracting(shown.map(\.frame))
          #expect(dropped.count <= 1, "frames dropped after resume: \(dropped.sorted())")
          let firstNew = try #require(shown.first { $0.frame > pausedFrame })
          #expect(firstNew.wall - resumedAt < 0.3)
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }
}
