import CLibVLC

/// State of an A-B loop on the player.
public enum ABLoopState: Sendable, Hashable, CustomStringConvertible {
  /// No loop is set.
  case none
  /// Point A has been set, waiting for point B.
  case pointASet
  /// Both points set, loop is active.
  case active

  public var description: String {
    switch self {
    case .none: "none"
    case .pointASet: "point A set"
    case .active: "active"
    }
  }

  init(from cValue: libvlc_abloop_t) {
    switch cValue {
    case libvlc_abloop_a: self = .pointASet
    case libvlc_abloop_b: self = .active
    default: self = .none
    }
  }
}
