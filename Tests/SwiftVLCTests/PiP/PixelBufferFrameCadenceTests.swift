#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Synchronization
import Testing

/// Direct PiP stamped every frame with exactly `1/30s` regardless of the
/// source. Sample duration is not decorative — AVFoundation uses it for
/// scheduling, pacing and backpressure — so a fabricated value misdescribes
/// every source that is not 30 fps, and nothing downstream can tell it was
/// fabricated.
@Suite(.tags(.logic))
struct PixelBufferFrameCadenceTests {
  /// The rates that matter, including the NTSC-derived ones a `Double` cannot
  /// represent exactly. The duration must be the exact rational, not a rounded
  /// reciprocal.
  @Test(arguments: [
    (num: UInt32(24000), den: UInt32(1001)),
    (num: UInt32(24), den: UInt32(1)),
    (num: UInt32(25), den: UInt32(1)),
    (num: UInt32(30000), den: UInt32(1001)),
    (num: UInt32(30), den: UInt32(1)),
    (num: UInt32(50), den: UInt32(1)),
    (num: UInt32(60000), den: UInt32(1001)),
    (num: UInt32(60), den: UInt32(1))
  ])
  func `A rational frame rate becomes an exact frame duration`(rate: (num: UInt32, den: UInt32)) throws {
    let duration = try #require(
      PixelBufferRenderer.frameDuration(rateNumerator: rate.num, rateDenominator: rate.den)
    )

    #expect(duration.value == CMTimeValue(rate.den))
    #expect(duration.timescale == CMTimeScale(rate.num))
    // Exact: value/timescale reproduces the rate without floating-point loss.
    #expect(duration.isNumeric)
    #expect(CMTimeValue(rate.num) * duration.value == CMTimeValue(rate.den) * CMTimeValue(duration.timescale))
  }

  /// 23.976 is the rate whose reciprocal a `Double` cannot hold exactly, so it
  /// is worth pinning that the rational survives into the `CMTime` untouched.
  ///
  /// Note the duration is carried in the source's *own* timescale. Rounding it
  /// into a general-purpose timescale is where the precision actually goes:
  /// 1001/24000 has no exact representation in the common 600 tick base, so a
  /// duration that had been routed through one would no longer sum to whole
  /// seconds over a long playback.
  @Test
  func `An NTSC rate keeps its exact rational form`() throws {
    let duration = try #require(
      PixelBufferRenderer.frameDuration(rateNumerator: 24000, rateDenominator: 1001)
    )

    #expect(duration == CMTime(value: 1001, timescale: 24000))
    #expect(duration.timescale == 24000, "the source timescale was not preserved")

    // 24000 frames of 1001/24000 is exactly 1001 seconds. A rounded duration
    // would not close.
    let oneThousandOneSeconds = CMTimeMultiply(duration, multiplier: 24000)
    #expect(oneThousandOneSeconds == CMTime(value: 1001, timescale: 1))

    // The same duration forced into a 600-tick base does not round-trip, which
    // is what preserving the source timescale avoids.
    let rounded = CMTimeConvertScale(duration, timescale: 600, method: .default)
    #expect(CMTimeConvertScale(rounded, timescale: 24000, method: .default) != duration)
  }

  @Test(arguments: [
    (num: UInt32(0), den: UInt32(1)),
    (num: UInt32(30), den: UInt32(0)),
    (num: UInt32(0), den: UInt32(0))
  ])
  func `An unreported cadence yields no duration`(rate: (num: UInt32, den: UInt32)) {
    #expect(
      PixelBufferRenderer.frameDuration(rateNumerator: rate.num, rateDenominator: rate.den) == nil
    )
  }

  /// The invariant the issue turns on: unknown cadence must not receive
  /// fabricated duration metadata.
  @Test
  func `An unknown cadence publishes an invalid duration, not a default`() {
    let renderer = PixelBufferRenderer()

    // Starts invalid rather than at some assumed rate.
    #expect(renderer.state.withLock { $0.frameDuration }.isValid == false)

    renderer.setFrameDuration(CMTime(value: 1001, timescale: 24000))
    #expect(renderer.state.withLock { $0.frameDuration } == CMTime(value: 1001, timescale: 24000))

    renderer.setFrameDuration(nil)
    #expect(
      renderer.state.withLock { $0.frameDuration }.isValid == false,
      "clearing the cadence left a stale duration describing the previous source"
    )
  }

  /// A nonsense duration is not better than none: zero or non-numeric values
  /// would describe an infinite frame rate.
  @Test(arguments: [CMTime.zero, CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity])
  func `A degenerate duration is rejected`(candidate: CMTime) {
    let renderer = PixelBufferRenderer()
    renderer.setFrameDuration(CMTime(value: 1, timescale: 25))

    renderer.setFrameDuration(candidate)

    #expect(renderer.state.withLock { $0.frameDuration }.isValid == false)
  }
}

/// Resolving the cadence from the player's track list, which is what feeds the
/// renderer on `.tracksChanged` and `.mediaChanged`.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPCadenceResolutionTests {
    private func videoTrack(
      id: String,
      isSelected: Bool,
      ratio: FrameRateRatio?
    ) -> Track {
      Track(
        id: id,
        type: .video,
        name: "Video \(id)",
        codec: 0,
        language: nil,
        trackDescription: nil,
        isSelected: isSelected,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: 1920,
        height: 1080,
        frameRate: ratio?.framesPerSecond,
        frameRateRatio: ratio,
        encoding: nil
      )
    }

    @Test
    func `No video tracks yields no cadence`() {
      let player = Player(instance: TestInstance.shared)
      #expect(PiPController.sourceFrameDuration(of: player) == nil)
    }

    /// A track list with no reported cadence must stay unknown rather than
    /// falling back to an assumed rate.
    @Test
    func `A track without a reported cadence yields no cadence`() {
      let player = Player(instance: TestInstance.shared)
      player.videoTracks = [videoTrack(id: "v0", isSelected: true, ratio: nil)]

      #expect(PiPController.sourceFrameDuration(of: player) == nil)
    }

    @Test
    func `The selected track's cadence wins`() throws {
      let player = Player(instance: TestInstance.shared)
      player.videoTracks = [
        videoTrack(id: "v0", isSelected: false, ratio: FrameRateRatio(numerator: 60, denominator: 1)),
        videoTrack(id: "v1", isSelected: true, ratio: FrameRateRatio(numerator: 24000, denominator: 1001))
      ]

      let duration = try #require(PiPController.sourceFrameDuration(of: player))

      #expect(duration == CMTime(value: 1001, timescale: 24000), "an unselected track's cadence won")
    }

    /// A track list can briefly show nothing selected right after a media
    /// change, and an unknown cadence there would stamp `.invalid` on frames
    /// whose rate the list already reports.
    @Test
    func `An unselected track's cadence is used when nothing is selected`() throws {
      let player = Player(instance: TestInstance.shared)
      player.videoTracks = [
        videoTrack(id: "v0", isSelected: false, ratio: nil),
        videoTrack(id: "v1", isSelected: false, ratio: FrameRateRatio(numerator: 25, denominator: 1))
      ]

      let duration = try #require(PiPController.sourceFrameDuration(of: player))

      #expect(duration == CMTime(value: 1, timescale: 25))
    }

    /// A selected track that reports no cadence must not silently adopt another
    /// track's rate — the selected one is what is being decoded.
    @Test
    func `A selected track without a cadence does not borrow another track's`() {
      let player = Player(instance: TestInstance.shared)
      player.videoTracks = [
        videoTrack(id: "v0", isSelected: true, ratio: nil),
        videoTrack(id: "v1", isSelected: false, ratio: FrameRateRatio(numerator: 50, denominator: 1))
      ]

      #expect(
        PiPController.sourceFrameDuration(of: player) == nil,
        "the decoded track reported no cadence but another track's rate was used"
      )
    }
  }
}
#endif
