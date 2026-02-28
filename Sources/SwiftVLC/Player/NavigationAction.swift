import CLibVLC

/// Navigation actions for DVD/Blu-ray menus.
public enum NavigationAction: Sendable, Hashable, CustomStringConvertible {
  /// Selects the currently highlighted menu item.
  case activate
  /// Moves the menu cursor up.
  case up
  /// Moves the menu cursor down.
  case down
  /// Moves the menu cursor left.
  case left
  /// Moves the menu cursor right.
  case right
  /// Opens or closes the disc popup menu.
  case popup

  public var description: String {
    switch self {
    case .activate: "activate"
    case .up: "up"
    case .down: "down"
    case .left: "left"
    case .right: "right"
    case .popup: "popup"
    }
  }

  var cValue: UInt32 {
    switch self {
    case .activate: UInt32(libvlc_navigate_activate.rawValue)
    case .up: UInt32(libvlc_navigate_up.rawValue)
    case .down: UInt32(libvlc_navigate_down.rawValue)
    case .left: UInt32(libvlc_navigate_left.rawValue)
    case .right: UInt32(libvlc_navigate_right.rawValue)
    case .popup: UInt32(libvlc_navigate_popup.rawValue)
    }
  }
}
