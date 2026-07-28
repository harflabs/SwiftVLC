/// An exact frame rate as libVLC reported it, numerator over denominator.
///
/// A `Double` cannot represent the NTSC-derived rates: 24000/1001 becomes
/// 23.976023976…, and a frame duration derived from that accumulates drift over
/// a long playback. Consumers that need exact timing — sample-buffer durations,
/// most of all — should use this rather than ``Track/frameRate``.
public struct FrameRateRatio: Sendable, Hashable {
  /// Frames per `denominator` seconds. For 23.976 fps this is `24000`.
  public let numerator: UInt32

  /// Seconds per `numerator` frames. For 23.976 fps this is `1001`.
  public let denominator: UInt32

  /// Creates a frame rate from libVLC's rational pair.
  ///
  /// - Returns: `nil` when either side is zero, which is how libVLC reports
  ///   "not known" rather than a real rate.
  public init?(numerator: UInt32, denominator: UInt32) {
    guard numerator > 0, denominator > 0 else { return nil }
    self.numerator = numerator
    self.denominator = denominator
  }

  /// The rate as frames per second. Lossy for NTSC rates by construction —
  /// prefer the rational form when the result feeds timing.
  public var framesPerSecond: Double {
    Double(numerator) / Double(denominator)
  }
}
