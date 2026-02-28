import Foundation

/// Typed error for all SwiftVLC operations.
/// Used with typed throws: `throws(VLCError)`.
public enum VLCError: Error, Sendable, CustomStringConvertible {
    case instanceCreationFailed
    case mediaCreationFailed(source: String)
    case playbackFailed(reason: String)
    case parseFailed(reason: String)
    case parseTimeout
    case trackNotFound(id: String)
    case invalidState(String)
    case operationFailed

    public var description: String {
        switch self {
        case .instanceCreationFailed:
            "Failed to create libVLC instance"
        case let .mediaCreationFailed(source):
            "Failed to create media from: \(source)"
        case let .playbackFailed(reason):
            "Playback failed: \(reason)"
        case let .parseFailed(reason):
            "Media parsing failed: \(reason)"
        case .parseTimeout:
            "Media parsing timed out"
        case let .trackNotFound(id):
            "Track not found: \(id)"
        case let .invalidState(message):
            "Invalid state: \(message)"
        case .operationFailed:
            "Operation failed"
        }
    }
}
