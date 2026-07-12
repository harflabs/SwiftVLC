#if os(iOS) || os(macOS)
import CLibVLC
import Foundation

/// One atomic post-rotation vmem source geometry snapshot. The orientation is
/// the original pre-rotation source value retained only for diagnostics; all
/// dimensions, crop offsets and SAR describe the normalized post-rotation
/// coordinate space delivered to the extended callback.
struct PixelBufferSourceGeometry: Equatable, Sendable {
  let codedWidth: UInt32
  let codedHeight: UInt32
  let visibleWidth: UInt32
  let visibleHeight: UInt32
  let xOffset: UInt32
  let yOffset: UInt32
  let sarNumerator: UInt32
  let sarDenominator: UInt32
  let sourceOrientationRawValue: UInt32

  init(_ geometry: swiftvlc_video_format_geometry_t) {
    codedWidth = geometry.coded_width
    codedHeight = geometry.coded_height
    visibleWidth = geometry.visible_width
    visibleHeight = geometry.visible_height
    xOffset = geometry.x_offset
    yOffset = geometry.y_offset
    sarNumerator = geometry.sar_num
    sarDenominator = geometry.sar_den
    sourceOrientationRawValue = geometry.source_orientation
  }

  init(fullFrameWidth width: UInt32, height: UInt32) {
    codedWidth = width
    codedHeight = height
    visibleWidth = width
    visibleHeight = height
    xOffset = 0
    yOffset = 0
    sarNumerator = 1
    sarDenominator = 1
    sourceOrientationRawValue = 0
  }

  var isValid: Bool {
    guard
      codedWidth > 0,
      codedHeight > 0,
      visibleWidth > 0,
      visibleHeight > 0,
      xOffset <= codedWidth,
      visibleWidth <= codedWidth - xOffset,
      yOffset <= codedHeight,
      visibleHeight <= codedHeight - yOffset,
      sarNumerator > 0,
      sarDenominator > 0
    else { return false }
    return sourceOrientationRawValue <= 7
  }

  /// Chooses an exact square-pixel delivery size without approximating PAR.
  /// Prefer expanding the affected axis so visible source resolution is not
  /// discarded. If that quotient is non-integral, the reciprocal contraction
  /// is accepted only when it is exact; otherwise setup fails closed.
  var squarePixelDeliveryDimensions: (width: UInt32, height: UInt32)? {
    guard isValid else { return nil }
    if sarNumerator == sarDenominator {
      return (visibleWidth, visibleHeight)
    }

    if sarNumerator > sarDenominator {
      if
        let width = exactScale(
          visibleWidth,
          multiplier: sarNumerator,
          divisor: sarDenominator
        ) {
        return (width, visibleHeight)
      }
      if
        let height = exactScale(
          visibleHeight,
          multiplier: sarDenominator,
          divisor: sarNumerator
        ) {
        return (visibleWidth, height)
      }
    } else {
      if
        let height = exactScale(
          visibleHeight,
          multiplier: sarDenominator,
          divisor: sarNumerator
        ) {
        return (visibleWidth, height)
      }
      if
        let width = exactScale(
          visibleWidth,
          multiplier: sarNumerator,
          divisor: sarDenominator
        ) {
        return (width, visibleHeight)
      }
    }
    return nil
  }

  private func exactScale(
    _ value: UInt32,
    multiplier: UInt32,
    divisor: UInt32
  ) -> UInt32? {
    let product = UInt64(value) * UInt64(multiplier)
    guard product.isMultiple(of: UInt64(divisor)) else { return nil }
    let quotient = product / UInt64(divisor)
    guard quotient > 0, quotient <= UInt64(UInt32.max) else { return nil }
    return UInt32(quotient)
  }
}
#endif
