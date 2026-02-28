import CLibVLC

/// The role of a media player, used to hint the system about audio behavior.
///
/// For example, setting `.music` may prevent system sounds from interrupting,
/// while `.communication` enables voice call processing.
public enum PlayerRole: Sendable, Hashable, CustomStringConvertible {
    case none
    case music
    case video
    case communication
    case game
    case notification
    case animation
    case production
    case accessibility
    case test

    public var description: String {
        switch self {
        case .none: "none"
        case .music: "music"
        case .video: "video"
        case .communication: "communication"
        case .game: "game"
        case .notification: "notification"
        case .animation: "animation"
        case .production: "production"
        case .accessibility: "accessibility"
        case .test: "test"
        }
    }

    var cValue: UInt32 {
        switch self {
        case .none: UInt32(libvlc_role_None.rawValue)
        case .music: UInt32(libvlc_role_Music.rawValue)
        case .video: UInt32(libvlc_role_Video.rawValue)
        case .communication: UInt32(libvlc_role_Communication.rawValue)
        case .game: UInt32(libvlc_role_Game.rawValue)
        case .notification: UInt32(libvlc_role_Notification.rawValue)
        case .animation: UInt32(libvlc_role_Animation.rawValue)
        case .production: UInt32(libvlc_role_Production.rawValue)
        case .accessibility: UInt32(libvlc_role_Accessibility.rawValue)
        case .test: UInt32(libvlc_role_Test.rawValue)
        }
    }

    init(from cValue: Int32) {
        switch libvlc_media_player_role(rawValue: UInt32(cValue)) {
        case libvlc_role_Music: self = .music
        case libvlc_role_Video: self = .video
        case libvlc_role_Communication: self = .communication
        case libvlc_role_Game: self = .game
        case libvlc_role_Notification: self = .notification
        case libvlc_role_Animation: self = .animation
        case libvlc_role_Production: self = .production
        case libvlc_role_Accessibility: self = .accessibility
        case libvlc_role_Test: self = .test
        default: self = .none
        }
    }
}
