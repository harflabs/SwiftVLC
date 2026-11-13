@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

private let nativeOutcomeTestsEnabled =
  ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1"

private func playbackFixture(_ name: String, _ ext: String) throws -> URL {
  try #require(Bundle.module.url(
    forResource: name, withExtension: ext, subdirectory: "Fixtures/playback"
  ))
}

private var frameIndexFixture: URL {
  Bundle.module.url(
    forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"
  )!
}

/// Collects the terminal causes a player publishes.
private final class TerminalCauses: Sendable {
  private final class Storage: Sendable {
    let causes = Mutex<[PlaybackTerminalCause]>([])
  }

  private let storage = Storage()
  private let task: Task<Void, Never>

  init(_ player: Player) {
    let outcomes = player.terminalOutcomes
    let storage = storage
    task = Task {
      for await outcome in outcomes {
        storage.causes.withLock { $0.append(outcome.cause) }
      }
    }
  }

  var all: [PlaybackTerminalCause] {
    storage.causes.withLock { $0 }
  }

  func cancel() {
    task.cancel()
  }
}

extension Integration {
  /// A failure that does not end the input (no video output, a missing
  /// subtitle file) made libVLC report Error for the rest of a healthy
  /// session and turned its clean end into a failure. An input that never
  /// exposed a stream ended "naturally" instead (patch 0065).
  @Suite(
    .serialized, .timeLimit(.minutes(2)),
    .enabled(if: nativeOutcomeTestsEnabled, "Requires the rebuilt native playback outcome contract")
  )
  @MainActor struct TerminalOutcomePlaybackTests {
    private func headlessInstance() throws -> VLCInstance {
      try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--vout=dummy", "--aout=dummy", "--no-hw-dec", "--quiet"
      ])
    }

    @Test
    func `a failed side stream leaves playback and its natural end intact`() async throws {
      let player = try Player(instance: headlessInstance())
      let causes = TerminalCauses(player)
      do {
        try player.play(Media(url: frameIndexFixture))
        try #require(await poll(timeout: .seconds(10)) {
          player.state == .playing && player.isSeekable && player.currentTime > .milliseconds(300)
        })
        let missing = FileManager.default.temporaryDirectory
          .appendingPathComponent("swiftvlc-missing-\(UUID().uuidString).srt")
        try player.addExternalTrack(from: missing, type: .subtitle)
        try await Task.sleep(for: .milliseconds(700))
        #expect(player.nativePlaybackState == .playing)

        player.pause()
        try #require(await poll(timeout: .seconds(3)) { player.state == .paused })
        #expect(player.nativePlaybackState == .paused)
        let pausedAt = player.currentTime
        player.resume()
        #expect(try await poll(timeout: .seconds(3)) {
          player.state == .playing && player.currentTime > pausedAt + .milliseconds(300)
        })

        _ = try player.requestSeek(to: .milliseconds(59000))
        try #require(await poll(timeout: .seconds(8)) { player.state == .stopped })
        #expect(player.didReachEnd)
        #expect(try await poll(timeout: .seconds(2)) { causes.all == [.naturalEnd] })
      } catch { causes.cancel(); await player.shutdown(); throw error }
      causes.cancel()
      await player.shutdown()
    }

    @Test
    func `data that exposes no stream fails instead of ending`() async throws {
      // Deterministic noise: no demuxer finds a stream in it.
      var value: UInt32 = 0x9E37_79B9
      var bytes = [UInt8](repeating: 0, count: 200_000)
      for index in bytes.indices {
        value = value &* 1_664_525 &+ 1_013_904_223
        bytes[index] = UInt8(truncatingIfNeeded: value >> 24)
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftvlc-noise-\(UUID().uuidString).mp4")
      try Data(bytes).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }

      let player = try Player(instance: headlessInstance())
      let causes = TerminalCauses(player)
      do {
        try player.play(Media(url: url))
        try #require(await poll(timeout: .seconds(10)) { player.state == .stopped })
        #expect(!player.didReachEnd)
        #expect(try await poll(timeout: .seconds(2)) { causes.all == [.failure(.demux)] })
      } catch { causes.cancel(); await player.shutdown(); throw error }
      causes.cancel()
      await player.shutdown()
    }
  }

  /// libVLC's time getters while paused: every redisplay of a paused picture
  /// moved the time back to that picture, and a seek without a video output
  /// kept reporting the position before the seek (patch 0066).
  @Suite(
    .serialized, .timeLimit(.minutes(2)),
    .enabled(if: nativeOutcomeTestsEnabled, "Requires the rebuilt native paused time contract")
  )
  @MainActor struct PausedTimePlaybackTests {
    @Test
    func `pausing on a stale picture keeps the playback time`() async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--aout=dummy", "--no-hw-dec", "--quiet"
      ])
      let player = Player(instance: instance)
      let sink = SeekVideoSink()
      do {
        try player.load(Media(url: playbackFixture("early-video-end", "mp4")))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        // The video track ends after one second.
        try #require(await poll(timeout: .seconds(10)) { player.currentTime > .milliseconds(2500) })
        player.pause()
        try #require(await poll(timeout: .seconds(3)) { player.state == .paused })
        // The paused picture is redisplayed every 80 ms.
        try await Task.sleep(for: .milliseconds(400))
        #expect(libvlc_media_player_get_time(player.pointer) >= 2400)
        #expect(player.currentTime >= .milliseconds(2400))
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }

  /// The same contracts where a headless host cannot produce the condition:
  /// a display that fails to open needs a window server, and the paused
  /// audio clock needs a real audio output. One skip reason per test, in
  /// both CI lanes.
  @Suite(.serialized, .timeLimit(.minutes(2)))
  @MainActor struct LocalOutputOutcomePlaybackTests {
    @Test(
      .enabled(
        if: nativeOutcomeTestsEnabled && TestCondition.canPlayMedia,
        "Requires the rebuilt release XCFramework and a window server"
      )
    )
    func `video without an output still ends naturally`() async throws {
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--quiet"]
      )
      let player = Player(instance: instance)
      let causes = TerminalCauses(player)
      do {
        try player.play(Media(url: TestMedia.twosecURL))
        try #require(await poll(timeout: .seconds(5)) {
          player.state == .playing && player.currentTime > .milliseconds(300)
        })
        try #require(
          player.activeVideoOutputs == 0,
          "precondition: libVLC must have abandoned the output without a drawable"
        )
        #expect(player.nativePlaybackState == .playing)
        try #require(await poll(timeout: .seconds(8)) { player.state == .stopped })
        #expect(player.didReachEnd)
        #expect(try await poll(timeout: .seconds(2)) { causes.all == [.naturalEnd] })
      } catch { causes.cancel(); await player.shutdown(); throw error }
      causes.cancel()
      await player.shutdown()
    }

    /// The other side of the same rule: video that was never shown, with
    /// nothing else presented, did not play.
    @Test(
      .enabled(
        if: nativeOutcomeTestsEnabled && TestCondition.canPlayMedia,
        "Requires the rebuilt release XCFramework and a window server"
      )
    )
    func `video that was never shown fails at its end`() async throws {
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--quiet"]
      )
      let player = Player(instance: instance)
      let causes = TerminalCauses(player)
      do {
        // Video only: with no output, nothing is ever presented.
        try player.play(Media(url: playbackFixture("inexact-sar", "mp4")))
        try #require(await poll(timeout: .seconds(8)) { player.state == .stopped })
        #expect(player.activeVideoOutputs == 0)
        #expect(!player.didReachEnd)
        #expect(try await poll(timeout: .seconds(2)) { causes.all == [.failure(.renderer)] })
      } catch { causes.cancel(); await player.shutdown(); throw error }
      causes.cancel()
      await player.shutdown()
    }

    @Test(
      .enabled(
        if: nativeOutcomeTestsEnabled && TestCondition.canPlayMedia,
        "Requires the rebuilt release XCFramework and an audio device"
      )
    )
    func `paused seeks on audio settle on their target`() async throws {
      // The real audio output is under test; keep it nearly silent.
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--no-video", "--gain=0.01", "--quiet"
      ])
      let player = Player(instance: instance)
      do {
        try player.play(Media(url: frameIndexFixture))
        try #require(await poll(timeout: .seconds(10)) {
          player.state == .playing && player.isSeekable && player.currentTime > .milliseconds(400)
        })
        player.pause()
        try #require(await poll(timeout: .seconds(3)) { player.state == .paused })
        try await Task.sleep(for: .milliseconds(200))
        for target: Int64 in [20000, 10000, 30000] {
          let clock = ContinuousClock()
          let start = clock.now
          let request = try player.requestSeek(to: .milliseconds(target))
          #expect(await request.outcome == .settled)
          #expect(clock.now - start < .seconds(1))
          #expect(libvlc_media_player_get_time(player.pointer) == target)
          #expect(player.currentTime == .milliseconds(target))
          #expect(player.activeNativeSeek == nil && player.queuedNativeSeek == nil)
        }
        player.resume()
        #expect(try await poll(timeout: .seconds(3)) {
          player.currentTime > .milliseconds(30200) && player.currentTime < .milliseconds(33000)
        })
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }

  /// The extended vmem output: a forced aspect ratio crashed the process and
  /// an inexact sample aspect ratio was rejected forever (patch 0067). A
  /// display restarted in place lost its rate (patch 0069).
  @Suite(
    .serialized, .timeLimit(.minutes(2)),
    .enabled(if: nativeOutcomeTestsEnabled, "Requires the rebuilt native video output contract")
  )
  @MainActor struct ExtendedVideoOutputPlaybackTests {
    private func videoOnlyInstance() throws -> VLCInstance {
      try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--no-audio", "--no-hw-dec", "--quiet"
      ])
    }

    @Test
    func `a forced aspect ratio keeps the extended output running`() async throws {
      let player = try Player(instance: videoOnlyInstance())
      let sink = SeekVideoSink()
      do {
        try player.load(Media(url: frameIndexFixture))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        try #require(await poll(timeout: .seconds(10)) { sink.count > 10 })
        libvlc_video_set_aspect_ratio(player.pointer, "4:3")
        let baseline = sink.count
        #expect(try await poll(timeout: .seconds(3)) { sink.count > baseline + 10 })
        #expect(player.state == .playing)
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }

    @Test
    func `an inexact sample aspect ratio is displayed`() async throws {
      let player = try Player(instance: videoOnlyInstance())
      let sink = SeekVideoSink()
      do {
        try player.load(Media(url: playbackFixture("inexact-sar", "mp4")))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        #expect(try await poll(timeout: .seconds(5)) { sink.count > 5 })
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }

    @Test
    func `the rate survives a display restart`() async throws {
      let player = try Player(instance: videoOnlyInstance())
      let sink = SeekVideoSink()
      do {
        try player.load(Media(url: playbackFixture("resolution-switch", "ts")))
        try installSeekVideoSink(sink, on: player)
        try player.play()
        try #require(await poll(timeout: .seconds(10)) { sink.count > 5 })
        try player.setPlaybackRate(.double)
        try #require(await poll(every: .milliseconds(20), timeout: .seconds(15)) {
          player.state == .stopped
        })
        // The first two seconds are 160x90; time the larger pictures only,
        // leaving the restart itself out.
        let first = try #require(sink.samples.withLock { $0.first }).pts
        let later = sink.samples.withLock { $0.filter { $0.pts - first > 3_000_000 } }
        let start = try #require(later.first)
        let end = try #require(later.last)
        try #require(end.wall > start.wall)
        let speed = Double(end.pts - start.pts) / 1_000_000 / (end.wall - start.wall)
        #expect(speed > 1.6 && speed < 2.4, "2x played at \(speed)x after the restart")
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
    }
  }
}
