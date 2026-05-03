/// Screen-anchor flags shared by ``Logo`` and ``Marquee``.
///
/// libVLC encodes overlay anchoring as an integer bitmask combining
/// independent horizontal (`left` / `right`) and vertical (`top` /
/// `bottom`) flags. An empty set anchors to the center; combine flags
/// with `OptionSet` syntax for corner anchors:
///
/// ```swift
/// player.logo.screenPosition = .topRight
/// player.marquee.screenPosition = [.bottom]   // bottom-center
/// player.logo.screenPosition = []             // center
/// ```
public struct OverlayPosition: OptionSet, Sendable, Hashable {
  public let rawValue: Int

  /// Wraps an arbitrary `Int` bitmask. Prefer the named statics
  /// (``left``, ``right``, ``top``, ``bottom``, ``topLeft``,
  /// ``topRight``, ``bottomLeft``, ``bottomRight``, ``center``) over
  /// raw integers.
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// No flags set — anchors to the center of the video.
  public static let center: OverlayPosition = []

  /// Anchor to the left edge.
  public static let left = OverlayPosition(rawValue: 1)

  /// Anchor to the right edge.
  public static let right = OverlayPosition(rawValue: 2)

  /// Anchor to the top edge.
  public static let top = OverlayPosition(rawValue: 4)

  /// Anchor to the bottom edge.
  public static let bottom = OverlayPosition(rawValue: 8)

  /// Top-left corner. Equivalent to `[.top, .left]`.
  public static let topLeft: OverlayPosition = [.top, .left]

  /// Top-right corner. Equivalent to `[.top, .right]`.
  public static let topRight: OverlayPosition = [.top, .right]

  /// Bottom-left corner. Equivalent to `[.bottom, .left]`.
  public static let bottomLeft: OverlayPosition = [.bottom, .left]

  /// Bottom-right corner. Equivalent to `[.bottom, .right]`.
  public static let bottomRight: OverlayPosition = [.bottom, .right]
}
