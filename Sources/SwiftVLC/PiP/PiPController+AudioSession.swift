#if os(iOS) || os(macOS)
import AVFoundation

// MARK: - Audio-session policy

extension PiPController {
  /// Live operation for deferred managed-session activation. Kept separate
  /// from the one-shot state machine so native-route tests can inject a
  /// deterministic failure/success sequence.
  static func liveAudioSessionActivation() throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    // Category setup can fail transiently too. Repeat it inside the same
    // retryable operation so a swallowed init-time failure cannot leave an
    // otherwise successful activation in the wrong audio category.
    try session.setCategory(.playback, mode: .moviePlayback)
    try session.setActive(true)
    #endif
  }

  /// Sets the shared audio session's category for movie playback when
  /// ``managesAudioSession`` is enabled. Activation is intentionally
  /// **not** done here: `setActive(true)` steals audio focus from other
  /// apps, and controllers are constructed at view-lifecycle times the
  /// app does not control. See ``activateAudioSessionIfNeeded()``.
  ///
  /// No-op on macOS, which has no `AVAudioSession`.
  func configureAudioSession() {
    #if os(iOS)
    guard managesAudioSession else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    #endif
  }

  /// Issues the deferred `AVAudioSession.setActive(true)` the first
  /// time PiP is started or playback becomes actively requested.
  /// No-op when ``managesAudioSession`` is `false`, after the first
  /// activation, and on platforms without `AVAudioSession`.
  func activateAudioSessionIfNeeded() {
    #if os(iOS)
    activateAudioSessionIfNeeded(using: audioSessionActivation)
    #endif
  }

  /// Runs the platform activation operation at most once after it succeeds.
  ///
  /// A failed operation deliberately leaves ``hasActivatedAudioSession`` false
  /// so a later playback/PiP signal can retry. The iOS production path above
  /// uses this same state machine; accepting the operation as an argument keeps
  /// the failure and retry behavior deterministic in platform-neutral tests.
  func activateAudioSessionIfNeeded(using activate: () throws -> Void) {
    guard managesAudioSession, !hasActivatedAudioSession else { return }
    do {
      try activate()
      hasActivatedAudioSession = true
    } catch {
      // Activation can fail transiently (for example during an audio-session
      // interruption). Leave the state unset so the next signal retries.
    }
  }
}

#endif
