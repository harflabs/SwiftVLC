import CLibVLC

/// The playback state of a ``Player``.
public enum PlayerState: Sendable, Hashable, CustomStringConvertible {
    case idle
    case opening
    case buffering(Float) // 0.0...1.0 (normalized, NOT 0-100)
    case playing
    case paused
    case stopped
    case stopping
    case ended
    case error

    public var description: String {
        switch self {
        case .idle: "idle"
        case .opening: "opening"
        case let .buffering(pct): "buffering(\(Int(pct * 100))%)"
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .stopping: "stopping"
        case .ended: "ended"
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
