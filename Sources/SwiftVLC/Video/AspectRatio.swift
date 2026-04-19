/// Video aspect ratio modes.
///
/// ```swift
/// player.aspectRatio = .ratio(16, 9)
/// ```
public enum AspectRatio: Sendable, Hashable, CustomStringConvertible {
  /// Preserve the source aspect ratio by fitting into the smaller dimension
  /// of the display (may add letterbox/pillarbox bars).
  case `default`

  /// Force a specific aspect ratio (e.g. `.ratio(16, 9)`).
  case ratio(Int, Int)

  /// Fill the display by fitting to the larger dimension (may crop content).
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
