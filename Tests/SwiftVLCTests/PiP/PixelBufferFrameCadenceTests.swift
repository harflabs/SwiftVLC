#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Testing

/// Direct PiP used to stamp every frame with `1/30s`, then briefly converted
/// libVLC's reported track ratio into one constant duration. Neither value is
/// authoritative for variable-frame-rate media: the vmem callback does not
/// expose an individual frame duration, while libVLC reports the 24→60 fps
/// regression fixture as the nominal/average ratio `42/1`.
@Suite(.tags(.logic))
struct PixelBufferFrameCadenceTests {
  @Test
  func `Direct PiP does not fabricate a sample duration`() {
    #expect(PixelBufferRenderer.sampleDuration.isValid == false)
  }

  @Test
  func `The reported ratio remains exact without claiming per-frame duration`() throws {
    let ratio = try #require(FrameRateRatio(numerator: 24000, denominator: 1001))

    #expect(ratio.numerator == 24000)
    #expect(ratio.denominator == 1001)
    #expect(ratio.framesPerSecond == Double(24000) / Double(1001))
  }

  @Test(arguments: [
    (numerator: UInt32(0), denominator: UInt32(1)),
    (numerator: UInt32(30), denominator: UInt32(0)),
    (numerator: UInt32(0), denominator: UInt32(0))
  ])
  func `An unreported ratio remains absent`(
    value: (numerator: UInt32, denominator: UInt32)
  ) {
    #expect(
      FrameRateRatio(
        numerator: value.numerator,
        denominator: value.denominator
      ) == nil
    )
  }
}
#endif
