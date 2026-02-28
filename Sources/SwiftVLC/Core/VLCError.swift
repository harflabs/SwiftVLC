import Foundation

/// Typed error for all SwiftVLC operations.
///
/// Used with Swift's typed throws: `throws(VLCError)`.
public enum VLCError: Error, Sendable, LocalizedError, CustomStringConvertible {
  /// The libVLC instance or player could not be allocated.
  case instanceCreationFailed
  /// A ``Media`` object could not be created from the given source.
  case mediaCreationFailed(source: String)
  /// Playback could not start.
  case playbackFailed(reason: String)
  /// Media metadata parsing failed before completion.
  case parseFailed(reason: String)
  /// Media metadata parsing exceeded the timeout.
  case parseTimeout
  /// No track matching the given identifier was found.
  case trackNotFound(id: String)
  /// The operation is not valid in the current playback state.
  case invalidState(String)
  /// A libVLC operation returned an error code.
  case operationFailed(_ operation: String)

  public var description: String {
    switch self {
    case .instanceCreationFailed:
      "Failed to create libVLC instance"
    case .mediaCreationFailed(let source):
      "Failed to create media from: \(source)"
    case .playbackFailed(let reason):
      "Playback failed: \(reason)"
    case .parseFailed(let reason):
      "Media parsing failed: \(reason)"
    case .parseTimeout:
      "Media parsing timed out"
    case .trackNotFound(let id):
      "Track not found: \(id)"
    case .invalidState(let message):
      "Invalid state: \(message)"
    case .operationFailed(let operation):
      "\(operation) failed"
    }
  }

  public var errorDescription: String? {
    description
  }
}
