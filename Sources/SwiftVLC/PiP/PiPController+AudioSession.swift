#if os(iOS) || os(macOS)
import AVFoundation

// MARK: - Audio-session policy

extension PiPController {
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
    guard managesAudioSession, !hasActivatedAudioSession else { return }
    hasActivatedAudioSession = true
    try? AVAudioSession.sharedInstance().setActive(true)
    #endif
  }
}

#endif
