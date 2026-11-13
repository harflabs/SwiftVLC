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

  /// Chooses the square-pixel delivery size.
  ///
  /// Prefer expanding the affected axis so visible source resolution is not
  /// discarded, then the reciprocal contraction, each only when its quotient
  /// is an integer. When neither is, the expanded axis is rounded to the
  /// nearest pixel: plenty of real material carries a sample aspect that no
  /// reasonable surface can express exactly (1920x816 at 817:816 would need a
  /// 4085x1734 one), and refusing it showed no picture at all. The rounded
  /// size is at most half a pixel from the exact one, which is the bound the
  /// vmem output accepts — see ``isWithinSquarePixelTolerance(width:height:)``.
  var squarePixelDeliveryDimensions: (width: UInt32, height: UInt32)? {
    guard isValid else { return nil }
    if sarNumerator == sarDenominator {
      return (visibleWidth, visibleHeight)
    }

    let expandsWidth = sarNumerator > sarDenominator
    let exactWidth = exactScale(
      visibleWidth,
      multiplier: sarNumerator,
      divisor: sarDenominator
    )
    let exactHeight = exactScale(
      visibleHeight,
      multiplier: sarDenominator,
      divisor: sarNumerator
    )
    if expandsWidth {
      if let exactWidth {
        return (exactWidth, visibleHeight)
      }
      if let exactHeight {
        return (visibleWidth, exactHeight)
      }
      return roundedScale(
        visibleWidth,
        multiplier: sarNumerator,
        divisor: sarDenominator
      ).map { ($0, visibleHeight) }
    }
    if let exactHeight {
      return (visibleWidth, exactHeight)
    }
    if let exactWidth {
      return (exactWidth, visibleHeight)
    }
    return roundedScale(
      visibleHeight,
      multiplier: sarDenominator,
      divisor: sarNumerator
    ).map { (visibleWidth, $0) }
  }

  /// Whether a delivery size shows the source at its display aspect to within
  /// half a pixel on one axis.
  ///
  /// The same inequality the vmem output applies to the size a format
  /// callback returns: with the source display aspect reduced to `num:den`,
  /// `2 * |width * den - height * num| <= max(num, den)`.
  func isWithinSquarePixelTolerance(width: UInt32, height: UInt32) -> Bool {
    guard isValid, width > 0, height > 0 else { return false }
    var numerator = UInt64(visibleWidth) * UInt64(sarNumerator)
    var denominator = UInt64(visibleHeight) * UInt64(sarDenominator)
    let divisor = Self.greatestCommonDivisor(numerator, denominator)
    numerator /= divisor
    denominator /= divisor

    let lhs = UInt64(width).multipliedFullWidth(by: denominator)
    let rhs = UInt64(height).multipliedFullWidth(by: numerator)
    // Reduced terms of real video stay far below 64 bits; anything that does
    // not is refused rather than compared with wrapped arithmetic.
    guard lhs.high == 0, rhs.high == 0 else { return false }
    let difference = lhs.low > rhs.low ? lhs.low - rhs.low : rhs.low - lhs.low
    let doubled = difference.multipliedReportingOverflow(by: 2)
    guard !doubled.overflow else { return false }
    return doubled.partialValue <= max(numerator, denominator)
  }

  private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var (a, b) = (lhs, rhs)
    while b != 0 {
      (a, b) = (b, a % b)
    }
    return max(a, 1)
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

  /// Nearest integer quotient, halves rounding up.
  private func roundedScale(
    _ value: UInt32,
    multiplier: UInt32,
    divisor: UInt32
  ) -> UInt32? {
    let product = UInt64(value) * UInt64(multiplier)
    let biased = product.addingReportingOverflow(UInt64(divisor) / 2)
    guard !biased.overflow else { return nil }
    let quotient = biased.partialValue / UInt64(divisor)
    guard quotient > 0, quotient <= UInt64(UInt32.max) else { return nil }
    return UInt32(quotient)
  }
}
#endif
