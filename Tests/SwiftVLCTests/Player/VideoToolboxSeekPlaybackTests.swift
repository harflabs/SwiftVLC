@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

#if SWIFTVLC_NATIVE_VIDEOTOOLBOX_TESTS
private let hasVideoToolboxTestSupport = true
@_silgen_name("swiftvlc_test_enable_videotoolbox")
private func enableVideoToolboxTestDevice(_ player: OpaquePointer)
#else
private let hasVideoToolboxTestSupport = false
#endif

extension Integration {
  @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: hasVideoToolboxTestSupport, "Requires the candidate VideoToolbox test support"))
  @MainActor struct VideoToolboxSeekPlaybackTests {
    @Test(arguments: [false, true], [false, true])
    func `paused seeks preserve recovery pixels and resume timing`(audio: Bool, hardware: Bool) async throws {
      #if SWIFTVLC_NATIVE_VIDEOTOOLBOX_TESTS
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
        "--aout=dummy", hardware ? "--codec=videotoolbox,avcodec" : "--codec=avcodec", "--verbose=2",
        audio ? "--audio" : "--no-audio"
      ])
      let hardwareSelected = Mutex(false)
      let softwareVideoSelected = Mutex(false)
      // Decoder selection is evidence: install before playback and keep the
      // short test's log lossless so a fast software startup cannot lose it.
      let logs = try #require(instance.logBroadcaster.subscribeAndWaitForInstallation(minimumLevel: .debug))
      let logTask = Task {
        for await entry in logs {
          if entry.message.contains("using video decoder module \"videotoolbox\"") {
            hardwareSelected.withLock { $0 = true }
          } else if entry.message.contains("using video decoder module \"avcodec\"") {
            softwareVideoSelected.withLock { $0 = true }
          }
        }
      }
      defer { logTask.cancel() }
      let player = Player(instance: instance)
      let sink = SeekVideoSink(capturePixels: true)
      do {
        let url = try #require(Bundle.module.url(forResource: "open-gop", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"))
        try player.load(Media(url: url))
        try installSeekVideoSink(sink, on: player)
        if hardware {
          enableVideoToolboxTestDevice(player.pointer)
        }
        try player.play()
        try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) {
          player.isSeekable && sink.count > 20
            && (hardware ? hardwareSelected.withLock { $0 } : softwareVideoSelected.withLock { $0 })
        })
        for cycle in 0..<2 {
          player.pause()
          try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) { player.state == .paused })
          for target in [7, 3, 9, 2, 6] {
            let request = try player.requestSeek(to: .seconds(target))
            try #require(await request.outcome == .settled)
            #expect(sink.latest?.frame == target * 30)
            let pixels = try #require(sink.latestPixels.withLock { $0 })
            let referenceURL = try #require(Bundle.module.url(forResource: "open-gop-\(target)", withExtension: "argb", subdirectory: "Fixtures/seek-oracle"))
            let reference = try Data(contentsOf: referenceURL)
            try #require(pixels.count == reference.count)
            // The clock and barcode can look correct while reference-dependent
            // parts of the picture are corrupt. Compare the whole decoded image
            // against independently decoded FFmpeg pixels, allowing rounding.
            let error = zip(pixels, reference).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            #expect(Double(error) / Double(reference.count) < 3)
            try await Task.sleep(for: target == 6 ? .seconds(cycle == 0 ? 1 : 3) : .milliseconds(200))
            #expect(sink.latest?.frame == target * 30)
            #expect(player.currentTime == .seconds(target))
          }
          player.resume()
          try await Task.sleep(for: .seconds(2))
          let outputTime = try Double(#require(sink.latest?.frame)) / 30
          #expect(softwareVideoSelected.withLock { $0 } == !hardware)
          #expect(outputTime >= 7 && outputTime <= 9)
          #expect(abs(Double(player.currentTime.milliseconds) / 1000 - outputTime) < 0.6)
        }
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
      withExtendedLifetime(sink) {}
      #endif
    }
  }
}
