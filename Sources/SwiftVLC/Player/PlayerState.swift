import CLibVLC

/// The playback state of a ``Player``.
public enum PlayerState: Sendable, Hashable, CustomStringConvertible {
  /// No media loaded or playback not yet started.
  case idle
  /// Media is being opened (connecting, demuxing).
  case opening
  /// Buffering in progress. The associated value is normalized (0.0–1.0).
  case buffering(Float)
  /// Media is actively playing.
  case playing
  /// Playback is paused.
  case paused
  /// Playback has stopped (end-of-media or explicit stop).
  case stopped
  /// Playback is in the process of stopping.
  case stopping
  /// A playback error occurred.
  case error

  public var description: String {
    switch self {
    case .idle: "idle"
    case .opening: "opening"
    case .buffering(let pct): "buffering(\(Int(pct * 100))%)"
    case .playing: "playing"
    case .paused: "paused"
    case .stopped: "stopped"
    case .stopping: "stopping"
    case .error: "error"
    }
  }

  init(from cState: libvlc_state_t) {
    switch cState {
    case libvlc_NothingSpecial: self = .idle
    case libvlc_Opening: self = .opening
    case libvlc_Buffering: self = .buffering(0)
    case libvlc_Playing: self = .playing
    case libvlc_Paused: self = .paused
    case libvlc_Stopped: self = .stopped
    case libvlc_Stopping: self = .stopping
    case libvlc_Error: self = .error
    default: self = .idle
    }
  }
}
