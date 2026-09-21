@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

extension Integration {
  @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1", "Requires native video output"))
  @MainActor struct ResumeTimelinePlaybackTests {
    @Test(arguments: [false, true], [false, true])
    func `subtitles cannot advance paused input after a seek`(audio: Bool, subtitles: Bool) async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--aout=dummy", "--no-hw-dec", "--quiet",
        audio ? "--audio" : "--no-audio", subtitles ? "--spu" : "--no-spu"
      ])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        let url = try #require(Bundle.module.url(forResource: "frame-subtitle", withExtension: "mkv", subdirectory: "Fixtures/seek-oracle"))
        try player.load(Media(url: url))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) {
          player.isSeekable && sink.count > 20
            && (!subtitles || player.subtitleTracks.contains(where: \.isSelected))
        })
        for target in [30, 15] {
          player.pause()
          try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
          let request = try player.requestSeek(to: .seconds(target))
          try #require(await request.outcome == .settled)
          #expect(sink.latest?.frame == target * 30)
          // Sparse subtitle packets used to keep requesting video frame-step
          // input, demuxing ahead for the entire paused interval.
          try await Task.sleep(for: .seconds(3))
          #expect(sink.latest?.frame == target * 30)
          #expect(abs((Double(player.currentTime.milliseconds) / 1000) - Double(target)) < 0.1)
          player.resume()
          try await Task.sleep(for: .seconds(2))
          let frame = try #require(sink.latest?.frame)
          let outputTime = Double(frame) / 30
          #expect(outputTime >= Double(target) + 1)
          #expect(outputTime <= Double(target) + 3)
          #expect(abs((Double(player.currentTime.milliseconds) / 1000) - outputTime) < 0.6)
          #expect(abs(Double(libvlc_media_player_get_time(player.pointer)) / 1000 - outputTime) < 0.6)
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }

    @Test(arguments: [false, true])
    func `start time clips but resume seeks preserve the full media timeline`(clipped: Bool) async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--no-hw-dec", "--quiet"])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        let url = try #require(Bundle.module.url(forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"))
        let media = try Media(url: url)
        if clipped {
          media.addOption(":start-time=20")
        }
        try player.load(media)
        try installSeekVideoSink(sink, on: player)
        try player.play()
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) {
          player.isSeekable && sink.count > 10 && player.duration != nil
        })
        player.pause()
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
        if !clipped {
          let resume = try player.requestSeek(to: .seconds(20))
          #expect(await resume.outcome == .settled)
          #expect(sink.latest?.frame == 600)
        }
        let request = try player.requestSeek(to: .seconds(5))
        let outcome = await request.outcome
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.duration == .seconds(clipped ? 40 : 60))
        #expect(sink.latest?.frame == (clipped ? 750 : 150))
        #expect(outcome == .settled)
        #expect(player.currentTime == .seconds(5))
        #expect(libvlc_media_player_get_time(player.pointer) == 5000)
        if !clipped {
          #expect(outcome == .settled)
          #expect(player.currentTime == .seconds(5))
          for target in [35, 20, 5, 45, 0, 30] {
            let request = try player.requestSeek(to: .seconds(target))
            #expect(await request.outcome == .settled)
            #expect(sink.latest?.frame == target * 30)
            #expect(player.currentTime == .seconds(target))
            #expect(player.duration == .seconds(60))
          }
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }

    @Test(arguments: [false, true])
    func `backward skip composes with a timed out queued scrub`(paused: Bool) async throws {
      let url = try #require(Bundle.module.url(forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"))
      let server = try MP4RangeProbeServer(data: Data(contentsOf: url))
      defer { server.stop() }
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--no-hw-dec", "--quiet"])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        try player.load(Media(url: server.url))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(15)) {
          player.isSeekable && (sink.latest?.frame ?? 0) >= 30
        })
        if paused {
          player.pause()
          try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
        }
        let baseline = sink.count
        server.delayFutureResponses()
        _ = try player.requestSeek(to: .seconds(36), fast: true)
        let scrub = try player.requestSeek(to: .seconds(20))
        #expect(await scrub.outcome == .timedOut)
        // The visible clock still belongs to the first native seek. A UI
        // computing currentTime - 15 would overwrite the queued 20s intent.
        let skip = try player.requestSeek(by: .seconds(-15))
        _ = await skip.outcome
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(20)) {
          player.activeNativeSeek == nil && player.queuedNativeSeek == nil
            && sink.samples.withLock { $0.dropFirst(baseline).contains { $0.frame == 150 } }
        })
        if paused {
          #expect(sink.latest?.frame == 150)
          #expect(player.currentTime == .seconds(5))
        } else {
          #expect(player.currentTime >= .seconds(5))
          #expect(player.currentTime < .seconds(7))
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }
}
