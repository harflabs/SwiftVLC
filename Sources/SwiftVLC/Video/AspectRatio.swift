/// Video aspect ratio modes.
///
/// ```swift
/// player.aspectRatio = .ratio(16, 9)
/// ```
public enum AspectRatio: Sendable, Hashable, CustomStringConvertible {
  /// Original aspect ratio (default).
  case `default`

  /// Specific aspect ratio (e.g. `.ratio(16, 9)`).
  case ratio(Int, Int)

  /// Fill the display area (may crop).
  case fill

  public var description: String {
    switch self {
    case .default: "default"
    case .ratio(let w, let h): "\(w):\(h)"
    case .fill: "fill"
    }
  }

  /// The VLC string representation, or nil for default behavior.
  var vlcString: String? {
    switch self {
    case .default: nil
    case .ratio(let w, let h): "\(w):\(h)"
    case .fill: nil
    }
  }
}
