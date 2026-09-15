@testable import SwiftVLC
import CLibVLC
import Darwin
import Foundation
import Synchronization
import Testing

extension Integration {
  @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1", "Requires the rebuilt native seek output contract"))
  @MainActor struct SeekOutputPlaybackTests {
    private var fixture: URL {
      Bundle.module.url(forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle")!
    }

    private var hlsFixture: URL {
      fixture.deletingLastPathComponent().appendingPathComponent("hls/index.m3u8")
    }

    private func prepare(_ player: Player, sink: SeekVideoSink, url: URL) throws {
      try player.load(Media(url: url))
      try installSeekVideoSink(sink, on: player)
      try player.play()
    }

    @Test(arguments: [false, true], [false, true])
    func `fresh HLS seek`(paused: Bool, directNative: Bool) async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--no-hw-dec", "--quiet"])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        try prepare(player, sink: sink, url: hlsFixture)
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) { player.isSeekable && (sink.latest?.frame ?? 0) >= 60 })
        if paused {
          player.pause()
          try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
        }
        try await Task.sleep(for: .milliseconds(300))
        let baseline = sink.count
        if directNative {
          #expect(libvlc_media_player_set_time(player.pointer, 23500, false) == 0)
        } else {
          let request = try player.requestSeek(to: .milliseconds(23500))
          #expect(await request.outcome == .settled)
        }
        let advanced = try await poll(every: .milliseconds(50), timeout: .seconds(8)) { sink.count > baseline && (sink.latest?.frame ?? 0) >= 690 }
        #expect(advanced)
        if paused {
          #expect(sink.latest?.frame == 705)
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }

    @Test(arguments: [false, true])
    func `delayed burst preserves final intent`(paused: Bool) async throws {
      let server = try MP4RangeProbeServer(data: Data(contentsOf: fixture))
      defer { server.stop() }
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--no-hw-dec", "--quiet"])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        try prepare(player, sink: sink, url: server.url)
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(15)) {
          player.isSeekable && (sink.latest?.frame ?? 0) >= 30
        })
        if paused {
          player.pause()
          try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
        }
        let baseline = sink.count
        server.delayFutureResponses()
        let first = try player.requestSeek(to: .seconds(36), fast: true)
        let final = try player.requestSeek(to: .seconds(12), fast: false)
        #expect(await first.outcome == .superseded)
        #expect(await final.outcome == .timedOut)
        // Both 2s observation windows expire before the two 3.5s range
        // responses. The final intent must still dispatch after A drains.
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(20)) {
          player.activeNativeSeek == nil && player.queuedNativeSeek == nil
            && sink.samples.withLock { $0.dropFirst(baseline).contains { $0.frame == 360 } }
        })
        #expect(server.rangeStarts.count >= 3)
        #expect(await final.outcome == .timedOut)
        if paused {
          #expect(sink.latest?.frame == 360)
          #expect(player.currentTime == .seconds(12))
          try await Task.sleep(for: .milliseconds(500))
          #expect(sink.latest?.frame == 360)
          #expect(player.currentTime == .seconds(12))
        } else {
          #expect(player.currentTime >= .seconds(12))
          #expect(player.currentTime < .seconds(14))
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }

    @Test(arguments: [false, true], ["mp4", "hls", "http-hls"])
    func `precise pixels`(audio: Bool, source: String) async throws {
      let hls = source != "mp4"
      let hlsRoot = fixture.deletingLastPathComponent().appendingPathComponent("hls")
      let resources = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
        at: hlsRoot, includingPropertiesForKeys: nil
      ).map { try ("/" + $0.lastPathComponent, Data(contentsOf: $0)) })
      // Accuracy cases use an unthrottled transport. Deadline behavior is
      // exercised separately with deterministic 3.5-second response delays.
      let server = try MP4RangeProbeServer(resources: resources, path: "/index.m3u8", chunkDelayMicroseconds: 0)
      defer { server.stop() }
      let url = source == "http-hls" ? server.url
        : hls ? hlsRoot.appendingPathComponent("index.m3u8") : fixture
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--no-hw-dec", "--quiet", audio ? "--audio" : "--no-audio"])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        try prepare(player, sink: sink, url: url)
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) { player.isSeekable && (sink.latest?.frame ?? 0) >= 15 })
        player.pause()
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
        for target: Int64 in [23500, 36500, 5400, 52500, 12333, 0, 59800, 59999, 18300] {
          let baseline = sink.count
          let request = try player.requestSeek(to: .milliseconds(target))
          let outcome = await request.outcome
          let atSettlement = try #require(sink.latest)
          #expect(sink.count > baseline)
          #expect(atSettlement.frame == min(1799, Int((target * 30 + 999) / 1000)))
          let observed = player.currentTime.components
          let observedSeconds = Double(observed.seconds) + Double(observed.attoseconds) / 1e18
          let settlementError = abs(observedSeconds - Double(atSettlement.frame) / 30)
          #expect(settlementError < 0.002)
          try await Task.sleep(for: .milliseconds(250))
          let actual = try #require(sink.latest)
          #expect(outcome == (target == 59999 ? .inaccurate : .settled))
          #expect(actual.frame == min(1799, Int((target * 30 + 999) / 1000)))
          let ptsMilliseconds = Double(actual.pts) / 1000
          let originMilliseconds: Double = hls ? 1466.666666 : 0
          let contentMilliseconds = Double(actual.frame) * 1000 / 30
          let ptsError = abs(ptsMilliseconds - originMilliseconds - contentMilliseconds)
          #expect(ptsError < 1)
          let c = player.currentTime.components
          let mirrorSeconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
          #expect(abs(mirrorSeconds - Double(actual.frame) / 30) < 0.002)
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }
}
