import CLibVLC

/// The playback state of a ``Player``.
///
/// The lifecycle is distinct from buffer fill: a player can be
/// `.paused` while libVLC is still buffering ahead, or `.playing`
/// while buffer levels fluctuate. Read ``Player/bufferFill``
/// separately when you need a fill percentage; it's published
/// continuously and is not gated by this enum.
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

  var isActive: Bool {
    switch self {
    case .playing, .opening, .buffering:
      true
    default:
      false
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

// MARK: - Per-case accessors

extension PlayerState {
  /// `true` when this state is `.idle`.
  public var isIdle: Bool {
    self == .idle
  }

  /// `true` when this state is `.opening`.
  public var isOpening: Bool {
    self == .opening
  }

  /// `true` when this state is `.buffering`.
  public var isBuffering: Bool {
    self == .buffering
  }

  /// `true` when this state is `.playing`.
  public var isPlaying: Bool {
    self == .playing
  }

  /// `true` when this state is `.paused`.
  public var isPaused: Bool {
    self == .paused
  }

  /// `true` when this state is `.stopped`.
  public var isStopped: Bool {
    self == .stopped
  }

  /// `true` when this state is `.stopping`.
  public var isStopping: Bool {
    self == .stopping
  }

  /// `true` when this state is `.error`.
  public var isError: Bool {
    self == .error
  }
}
