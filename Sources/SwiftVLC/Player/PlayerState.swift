import CLibVLC

/// The playback state of a ``Player``.
///
/// The lifecycle is distinct from buffer fill: a player can be `.paused`
/// while libVLC is still buffering ahead, or `.playing` while buffer
/// levels fluctuate. Read ``Player/bufferFill`` separately when you want
/// to display fill percentage — it's published continuously and is not
/// gated by this enum.
public enum PlayerState: Sendable, Hashable, CustomStringConvertible {
  /// No media loaded or playback not yet started.
  case idle
  /// Media is being opened (connecting, demuxing).
  case opening
  /// Waiting for enough data to start (or resume) playback.
  case buffering
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
    case .buffering: "buffering"
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
    case libvlc_Buffering: self = .buffering
    case libvlc_Playing: self = .playing
    case libvlc_Paused: self = .paused
    case libvlc_Stopped: self = .stopped
    case libvlc_Stopping: self = .stopping
    case libvlc_Error: self = .error
    default: self = .idle
    }
  }
}
