/// Video aspect ratio modes.
///
/// ```swift
/// player.aspectRatio = .ratio(16, 9)
/// ```
public enum AspectRatio: Sendable, Hashable, CustomStringConvertible {
  /// Preserve the source aspect ratio, fitted inside the display
  /// (letterbox/pillarbox bars where the shapes differ).
  case `default`

  /// Force the picture to a specific display aspect ratio, stretching the
  /// source to that shape (e.g. `.ratio(16, 9)`); the shaped picture is then
  /// fitted inside the display.
  case ratio(Int, Int)

  /// Fill the display, preserving the source aspect and cropping the
  /// overflow (cover).
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
