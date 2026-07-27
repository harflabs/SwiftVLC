/// The result of ``Player/recast(to:)``, describing whether the replacement
/// session actually settled.
///
/// Recasting tears down the current session and starts a new one on a
/// different renderer, then restores the previous position, track selection
/// and paused state. Every one of those steps can fail to complete: the new
/// session may never reach playback, it may fail asynchronously, the caller's
/// task may be cancelled mid-restore, or another recast or media load may take
/// over. Returning `Void` made all of those indistinguishable from a clean
/// hand-off.
///
/// Only ``settled`` means the replacement session is playing and every piece
/// of carried-over state was reapplied.
public enum RecastOutcome: Sendable, Equatable {
  /// The replacement session reached playback and the prior position, track
  /// selection and paused state were restored.
  case settled

  /// The replacement session reported a native error instead of settling.
  /// The renderer change has already taken effect; the old session is gone.
  case failed

  /// The replacement session never reached playback within the defensive
  /// ceiling. It may still be opening.
  case timedOut

  /// The awaiting task was cancelled. No further media, seek, track,
  /// renderer or transport mutation was performed after that point, so the
  /// session is left wherever cancellation found it.
  case cancelled

  /// Another ``Player/recast(to:)`` or a media load took over before this one
  /// finished restoring. The newer operation owns the session; this one
  /// stopped touching it.
  case superseded

  /// Whether the replacement session is playing with all carried-over state
  /// reapplied.
  ///
  /// `true` only for ``settled``. Prefer this to comparing against individual
  /// failure cases so a future outcome cannot silently read as success.
  public var isSettled: Bool {
    self == .settled
  }
}
