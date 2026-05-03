import Foundation

/// The single error type thrown by every failable SwiftVLC API.
///
/// All throwing functions in SwiftVLC use Swift's typed throws form
/// `throws(VLCError)`, so the cases below are exhaustive. A general
/// `catch` is unnecessary when the compiler can statically see that
/// this is the only possible error.
///
/// Every case carries enough context (URL, operation name, reason string)
/// to log meaningfully without consulting libVLC's own diagnostics.
public enum VLCError: Error, Sendable, Equatable, Hashable, LocalizedError, CustomStringConvertible {
  /// libVLC could not allocate an instance, player, or discoverer.
  ///
  /// Typically indicates that the `libvlc.xcframework` is not linked
  /// correctly, required plugins are missing, or the process is out of
  /// memory.
  case instanceCreationFailed
  /// A ``Media`` object could not be created from the given URL, path,
  /// or file descriptor.
  case mediaCreationFailed(source: String)
  /// Playback could not start. The `reason` is libVLC's most recent
  /// error message at the time the call failed.
  case playbackFailed(reason: String)
  /// Parsing ended with a non-success status before the timeout expired
  /// (e.g. the resource was unreachable or malformed).
  case parseFailed(reason: String)
  /// Parsing did not complete within the requested timeout.
  case parseTimeout
  /// The requested track identifier does not match any track on the
  /// current media.
  case trackNotFound(id: String)
  /// The operation is valid in principle but not in the player's
  /// current state (e.g. setting an A-B loop before any media is
  /// loaded). The associated string names the constraint that failed.
  case invalidState(String)
  /// A libVLC call returned a non-zero error code. The associated
  /// string names the operation that was attempted.
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

// MARK: - Per-case accessors

extension VLCError {
  /// `Void` if this error is `.instanceCreationFailed`, otherwise `nil`.
  public var instanceCreationFailed: Void? {
    if case .instanceCreationFailed = self { () } else { nil }
  }

  /// Source string if this error is `.mediaCreationFailed`, otherwise `nil`.
  public var mediaCreationFailed: String? {
    if case .mediaCreationFailed(let value) = self { value } else { nil }
  }

  /// Reason string if this error is `.playbackFailed`, otherwise `nil`.
  public var playbackFailed: String? {
    if case .playbackFailed(let value) = self { value } else { nil }
  }

  /// Reason string if this error is `.parseFailed`, otherwise `nil`.
  public var parseFailed: String? {
    if case .parseFailed(let value) = self { value } else { nil }
  }

  /// `Void` if this error is `.parseTimeout`, otherwise `nil`.
  public var parseTimeout: Void? {
    if case .parseTimeout = self { () } else { nil }
  }

  /// Track id string if this error is `.trackNotFound`, otherwise `nil`.
  public var trackNotFound: String? {
    if case .trackNotFound(let value) = self { value } else { nil }
  }

  /// Constraint message if this error is `.invalidState`, otherwise `nil`.
  public var invalidState: String? {
    if case .invalidState(let value) = self { value } else { nil }
  }

  /// Operation name if this error is `.operationFailed`, otherwise `nil`.
  public var operationFailed: String? {
    if case .operationFailed(let value) = self { value } else { nil }
  }
}
