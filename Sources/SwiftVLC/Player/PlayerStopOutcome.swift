/// The result of ``Player/stopAndWait()``, describing whether the native
/// audio and video outputs are known to have been released.
///
/// ``Player/stopAndWait()`` exists so callers have a point in time after
/// which nothing is still draining — most commonly before
/// `AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)`,
/// which fails session-busy while an audio output is alive, or before
/// detaching a drawable. Only ``stopped`` establishes that. The remaining
/// cases all mean *outputs may still be draining*, and are distinguished so a
/// caller can retry, back off, or surface the condition instead of proceeding
/// on a promise that was not kept.
///
/// There is deliberately no `cancelled` case. Cancelling a caller does not
/// abandon the drain: the stop runs to completion and every caller is told
/// the real output state. Returning early on cancellation would hand back a
/// result indistinguishable from success while an audio output was still
/// alive, which is the failure this type exists to prevent.
public enum PlayerStopOutcome: Sendable, Equatable {
  /// The native player reached its stopped state and released its outputs.
  /// This is the only outcome that makes immediate teardown safe.
  case stopped

  /// The defensive ceiling elapsed before the native player reported
  /// stopped. Outputs may still be draining.
  case timedOut

  /// The session ended in a native error and no stopped state followed
  /// within the defensive ceiling.
  ///
  /// A libVLC error is *not* by itself an output-safe condition: an error
  /// is reported first and the stopped state that actually releases the
  /// outputs arrives afterwards. This outcome means that follow-up never
  /// came, so outputs may still be draining.
  case failedButStillDraining

  /// Whether the native outputs are known to have been released.
  ///
  /// `true` only for ``stopped``. Use this rather than testing for
  /// individual failure cases, so a future outcome cannot silently read as
  /// success.
  public var isOutputSafe: Bool {
    self == .stopped
  }
}
