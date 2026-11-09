@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

extension Integration {
  /// At an HLS `EXT-X-DISCONTINUITY` the adaptive demuxer resets the PCR. It
  /// used to do so while the decoders still held up to the caching delay of the
  /// previous timeline, so about a second of video before every discontinuity
  /// was never displayed, and it mapped the new sequence through the previous
  /// sequence's timestamps, so the player time clamped to the duration or
  /// restarted near zero (patch 0063).
  @Suite(
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(
      if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1",
      "Requires native video output"
    )
  )
  @MainActor struct HLSDiscontinuityPlaybackTests {
    @Test(arguments: [false, true])
    func `discontinuities present every frame and keep the playlist time`(audio: Bool) async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--aout=dummy", "--no-hw-dec", "--quiet", audio ? "--audio" : "--no-audio"
      ])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        // Three 4-second sequences of barcode frames 0-359 whose timestamps
        // jump by +3000 s at frame 120 and back at frame 240.
        let url = try #require(Bundle.module.url(
          forResource: "index", withExtension: "m3u8",
          subdirectory: "Fixtures/seek-oracle/hls-discontinuity"
        ))
        try player.load(Media(url: url))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        for jump in [120, 240] {
          try #require(await poll(every: .milliseconds(10), timeout: .seconds(20)) {
            (sink.latest?.frame ?? 0) >= jump + 45
          })
          let shown = Set(sink.samples.withLock { $0.map(\.frame) })
          let dropped = Set(jump - 30..<jump).subtracting(shown)
          #expect(dropped.count <= 2, "frames dropped before the discontinuity: \(dropped.sorted())")
          // Media time follows the playlist across the jump: frame n plays at n / 30 s.
          #expect(try await poll(timeout: .seconds(3)) {
            guard let frame = sink.latest?.frame else { return false }
            let time = Double(libvlc_media_player_get_time(player.pointer)) / 1000
            return abs(time - Double(frame) / 30) < 0.5
          })
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }
}
