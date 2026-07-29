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

  // MARK: - Session disruption

  /// A disruption to the shared audio session that the managed path reacts to.
  ///
  /// Modelled as a value rather than read from `Notification` at the decision
  /// point so the policy below can be exercised without an `AVAudioSession` —
  /// there is none on macOS, and CI cannot produce a real interruption on any
  /// platform.
  enum AudioSessionDisruption: Equatable, Sendable {
    /// The system took audio focus away. It has already deactivated our
    /// session; nothing needs deactivating in response.
    case interruptionBegan
    /// Focus was returned. `shouldResume` mirrors AVKit's
    /// `.shouldResume` option, which is the system's opinion — not consent.
    case interruptionEnded(shouldResume: Bool)
    /// The route the audio was playing out of went away, e.g. headphones
    /// unplugged or Bluetooth disconnected.
    case routeLost
    /// The media server restarted. Every session object is invalid and the
    /// category has to be set again from scratch.
    case mediaServicesReset
  }

  /// What a disruption implies for the managed session.
  struct AudioSessionReaction: Equatable, Sendable {
    /// Clear ``hasActivatedAudioSession`` so a later signal can reactivate.
    /// Without this the latch is permanent and audio never returns.
    var clearsActivationLatch = false
    /// Reconfigure the category before reactivating.
    var reconfiguresCategory = false
    /// Reactivate the session now.
    var reactivates = false
    /// Pause playback, because continuing would be wrong rather than merely
    /// silent.
    var pausesPlayback = false
  }

  /// Decides the response to a session disruption.
  ///
  /// Pure, and separated from the notification plumbing because every input
  /// here originates in an `AVAudioSession` notification that no test on this
  /// host can raise. The rules follow Apple's documented handling rather than
  /// being invented:
  ///
  /// - An interruption deactivates the session on our behalf, so the only
  ///   thing to undo is the latch. Reactivating here would fight whatever took
  ///   focus.
  /// - Resuming afterwards needs *both* the system's `.shouldResume` hint and
  ///   the user's playback intent. The hint alone is not enough: someone who
  ///   paused before the call must not find playback running after it.
  /// - Losing the output route pauses. This is the headphone-unplug rule —
  ///   continuing would move the audio to the speaker, which is the one
  ///   outcome the user certainly did not ask for.
  /// - A media-services reset invalidates everything, so the category must be
  ///   set again before activation, and only if playback was wanted.
  ///
  /// With ``managesAudioSession`` disabled every reaction is empty: a library
  /// that was told not to touch the session must not touch it on the way out
  /// either.
  nonisolated static func reaction(
    to disruption: AudioSessionDisruption,
    isPlaybackIntentActive: Bool,
    managesAudioSession: Bool
  )
    -> AudioSessionReaction {
    guard managesAudioSession else { return AudioSessionReaction() }

    switch disruption {
    case .interruptionBegan:
      return AudioSessionReaction(clearsActivationLatch: true)

    case .interruptionEnded(let shouldResume):
      let resumes = shouldResume && isPlaybackIntentActive
      return AudioSessionReaction(clearsActivationLatch: !resumes, reactivates: resumes)

    case .routeLost:
      // The session itself is still valid, so the latch stands.
      return AudioSessionReaction(pausesPlayback: true)

    case .mediaServicesReset:
      return AudioSessionReaction(
        clearsActivationLatch: !isPlaybackIntentActive,
        reconfiguresCategory: true,
        reactivates: isPlaybackIntentActive
      )
    }
  }

  /// Applies a decided reaction. Split from ``reaction(to:isPlaybackIntentActive:managesAudioSession:)``
  /// so the rules stay testable and only the effects need a live session.
  func apply(_ reaction: AudioSessionReaction) {
    if reaction.clearsActivationLatch {
      hasActivatedAudioSession = false
    }
    if reaction.reconfiguresCategory {
      configureAudioSession()
    }
    if reaction.reactivates {
      // Reactivation goes through the same one-shot machine as the first
      // activation, so a failure here leaves the latch clear and the next
      // playback signal retries — rather than latching a session that is not
      // actually active.
      hasActivatedAudioSession = false
      activateAudioSessionIfNeeded()
    }
    if reaction.pausesPlayback {
      _ = playbackDriver.pause()
    }
  }

  #if os(iOS)
  /// Subscribes to the session disruptions the managed path reacts to.
  ///
  /// Only when ``managesAudioSession`` is set: with it clear the library must
  /// not observe the session either, since reacting would mean mutating a
  /// session the host app owns.
  func startAudioSessionObservers() {
    guard managesAudioSession else { return }
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()

    audioSessionObservers = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        MainActor.assumeIsolated {
          self?.handleInterruption(rawType: raw, rawOptions: options)
        }
      },
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        MainActor.assumeIsolated {
          self?.handleRouteChange(rawReason: raw)
        }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.react(to: .mediaServicesReset)
        }
      }
    ]
  }

  func stopAudioSessionObservers() {
    for observer in audioSessionObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    audioSessionObservers.removeAll()
  }

  private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
    guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
    switch type {
    case .began:
      react(to: .interruptionBegan)
    case .ended:
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
      react(to: .interruptionEnded(shouldResume: options.contains(.shouldResume)))
    @unknown default:
      break
    }
  }

  private func handleRouteChange(rawReason: UInt?) {
    guard
      let rawReason,
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
      reason == .oldDeviceUnavailable
    else { return }
    react(to: .routeLost)
  }
  #endif

  /// Platform-neutral entry points, so the shared initializers and `deinit`
  /// do not need their own `#if`. macOS has no `AVAudioSession` and nothing to
  /// observe.
  func startAudioSessionObserversIfManaged() {
    #if os(iOS)
    startAudioSessionObservers()
    #endif
  }

  func stopAudioSessionObserversIfManaged() {
    #if os(iOS)
    stopAudioSessionObservers()
    #endif
  }

  /// Resolves and applies the reaction for a disruption.
  func react(to disruption: AudioSessionDisruption) {
    apply(
      Self.reaction(
        to: disruption,
        isPlaybackIntentActive: player.isPlaybackRequestedActive,
        managesAudioSession: managesAudioSession
      )
    )
  }
}

#endif
