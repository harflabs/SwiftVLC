import CLibVLC

/// Playback mode for a media list player.
public enum PlaybackMode: Sendable, Hashable, CustomStringConvertible {
  /// Play through the list once and stop.
  case `default`
  /// Loop the entire list.
  case loop
  /// Repeat the current item.
  case `repeat`

  public var description: String {
    switch self {
    case .default: "default"
    case .loop: "loop"
    case .repeat: "repeat"
    }
  }

  var cValue: libvlc_playback_mode_t {
    switch self {
    case .default: libvlc_playback_mode_default
    case .loop: libvlc_playback_mode_loop
    case .repeat: libvlc_playback_mode_repeat
    }
  }
}
