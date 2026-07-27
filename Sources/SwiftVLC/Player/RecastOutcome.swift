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
/// Only ``settled`` means the recast ran to completion. It does not promise
/// that every piece of carried-over state was reapplied — restoration is
/// best-effort by design, and the cases where it is skipped are documented on
/// ``settled`` and on ``Player/recast(to:)``.
public enum RecastOutcome: Sendable, Equatable {
  /// The recast completed: the renderer change is in effect, and where a
  /// session existed it reached playback and its paused state was honoured.
  ///
  /// Position and track restoration are **best-effort**, so this is also
  /// returned when they could not be applied:
  ///
  /// - A player that had never started playback is a plain renderer change
  ///   with no session to rebuild, so nothing needs restoring.
  /// - A session that never reports seekability — live streams never do —
  ///   keeps its restart position instead of resuming the prior one.
  /// - Tracks that never appear stay at the new session's defaults; ids are
  ///   session-scoped and the match is by language then name.
  ///
  /// What ``settled`` does rule out is the session having failed, never
  /// arrived, been abandoned, or been taken over.
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

  /// Whether the recast ran to completion.
  ///
  /// `true` only for ``settled`` — see that case for what completion does and
  /// does not guarantee. Prefer this to comparing against individual failure
  /// cases so a future outcome cannot silently read as success.
  public var isSettled: Bool {
    self == .settled
  }
}
