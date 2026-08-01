#if os(iOS) || os(macOS)

extension PiPController {
  /// Cancels any in-flight scheduled pause. This **only** cancels the
  /// `.scheduled` task; an already-`.issued` pause is preserved —
  /// `requestResumeIfNeeded` reads it to decide whether to issue a libVLC
  /// resume.
  func cancelDeferredPause() {
    if case .scheduled(let task, _) = deferredPause {
      task.cancel()
      deferredPause = .idle
      // A pause that is cancelled before it can be issued is a cancellation,
      // whichever caller cancelled it. `scheduleDeferredPause` clears this
      // again straight afterwards, so a supersede reads as "in flight"
      // rather than as the superseded attempt's outcome.
      setDeferredPauseOutcome(.cancelled)
    }
  }

  /// Schedules a deferred pause, replacing any in-flight one. The task
  /// sleeps for `pauseDebounce`, re-checks intent and player state on
  /// wake, and either issues the libVLC pause (transitioning to
  /// `.issued`) or exits cleanly (transitioning back to `.idle`).
  func scheduleDeferredPause() {
    cancelDeferredPause()
    // A new attempt is in flight and has not finished yet. Without this the
    // previous attempt's outcome would stay readable for the whole debounce,
    // so a reader could not tell a settled result from a stale one.
    setDeferredPauseOutcome(nil)

    let generation = DeferredPauseState.nextGeneration(after: deferredPause)
    // The native callback lane can advance before the main actor adopts the
    // corresponding mediaChanged event. Bind the delayed command to that
    // authoritative generation so an outgoing pause cannot reach a successor
    // during the adoption gap.
    let playbackGeneration = player.eventBridge.currentPlaybackGeneration
    let startingPlaybackControlIntent = player.playbackControlIntent
    let startingPlaybackControlRevision = player.playbackControlIntentRevision
    let debounce = pauseDebounce
    let task = Task { @MainActor [weak self] in
      var attemptsRemaining = Self.maxDeferredPauseAttempts
      // The first native attempt is the fresh PiP transport command. Later
      // calls are retries of that same command and must not overwrite a newer
      // playlist play/resume intent that arrived between attempts.
      var hasAttemptedPlayerPause = false
      var ownedPlaybackControlRevision: UInt64?
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: debounce)
        } catch {
          return
        }

        // Bind `self` after the suspension so the observer only keeps the
        // controller alive while it is deciding whether to issue the pause.
        guard let self else { return }
        #if DEBUG
        _deferredPauseRetryHookForTesting?()
        #endif
        guard !Task.isCancelled, currentDeferredPauseGeneration == generation, !pipPlaybackActive else { return }
        let expectedPlaybackControlRevision = ownedPlaybackControlRevision
          ?? startingPlaybackControlRevision
        guard player.playbackControlIntentRevision == expectedPlaybackControlRevision else {
          deferredPause = .idle
          setDeferredPauseOutcome(.cancelled)
          return
        }
        guard player.eventBridge.currentPlaybackGeneration == playbackGeneration else {
          if let ownedPlaybackControlRevision {
            playbackDriver.cancelPendingPause(
              playbackGeneration,
              ownedPlaybackControlRevision,
              startingPlaybackControlIntent ?? .resume
            )
          }
          deferredPause = .idle
          setDeferredPauseOutcome(.cancelled)
          return
        }
        if
          let ownedPlaybackControlRevision,
          player.didIssuePause(
            playbackGeneration: playbackGeneration,
            playbackControlRevision: ownedPlaybackControlRevision
          ) {
          // Player's event lane can retry a retained command while this task
          // sleeps. That native acceptance belongs to this exact PiP command
          // even though it did not come from the synchronous attempt below.
          deferredPause = .issued
          setDeferredPauseOutcome(.issued)
          return
        }

        switch player.state {
        case .playing:
          let recordsPlaybackControlIntent = !hasAttemptedPlayerPause
          hasAttemptedPlayerPause = true
          let attempt = playbackDriver.pause(
            playbackGeneration,
            recordsPlaybackControlIntent
          )
          if let playbackControlRevision = attempt.playbackControlRevision {
            ownedPlaybackControlRevision = playbackControlRevision
          }
          if attempt.accepted {
            deferredPause = .issued
            setDeferredPauseOutcome(.issued)
            return
          }
          // libVLC refused. Retry, but not forever.
          attemptsRemaining -= 1
        case .opening, .buffering:
          // Avoid pausing libVLC while it is still stabilizing input state.
          // Keep waiting unless AVKit changes its mind first — bounded, so an
          // input that never stabilizes cannot retry indefinitely.
          attemptsRemaining -= 1
        default:
          deferredPause = .idle
          setDeferredPauseOutcome(.cancelled)
          return
        }

        if attemptsRemaining <= 0 {
          deferredPause = .idle
          settleUnpausableInput(
            playbackGeneration: playbackGeneration,
            startingPlaybackControlIntent: startingPlaybackControlIntent,
            startingPlaybackControlRevision: startingPlaybackControlRevision,
            ownedPlaybackControlRevision: ownedPlaybackControlRevision
          )
          return
        }
      }
    }
    deferredPause = .scheduled(task: task, generation: generation)
  }

  /// How many debounce intervals a deferred pause may retry before the input
  /// is treated as unpausable.
  ///
  /// At the default 250 ms debounce this is ten seconds — long enough for a
  /// slow network open to stabilize, short enough that a permanently
  /// unpausable input does not leave a paused UI over continuing playback
  /// indefinitely.
  static let maxDeferredPauseAttempts = 40

  /// Reconciles after a deferred pause has been abandoned.
  ///
  /// The input never became pausable, so playback is still running. The
  /// public intent was already published as inactive when PiP asked to pause;
  /// leaving it there would show paused controls over playing media — the
  /// visible half of this bug. Republish the truth on both surfaces.
  private func settleUnpausableInput(
    playbackGeneration: UInt64,
    startingPlaybackControlIntent: Player.DeferredPauseCommand?,
    startingPlaybackControlRevision: UInt64,
    ownedPlaybackControlRevision: UInt64?
  ) {
    let expectedPlaybackControlRevision = ownedPlaybackControlRevision
      ?? startingPlaybackControlRevision
    guard
      player.playbackControlIntentRevision == expectedPlaybackControlRevision,
      startingPlaybackControlIntent != .pause,
      ownedPlaybackControlRevision != nil || player.playbackControlIntent != .pause
    else {
      setDeferredPauseOutcome(.cancelled)
      return
    }
    // `issuePause` can reject synchronously while retaining a player-owned
    // deferred command for a later pausable/time event. Retire that command
    // before publishing a terminal result, or it could pause playback after
    // observers were told this attempt had been rejected.
    playbackDriver.cancelPendingPause(
      playbackGeneration,
      ownedPlaybackControlRevision,
      .resume
    )
    setDeferredPauseOutcome(.rejected)
    guard player.state.isActive else { return }
    player.setPlaybackIntentFromExternalControl(true)
    pipPlaybackActive = true
    invalidatePictureInPicturePlaybackState()
  }

  /// The generation id of an in-flight scheduled pause, or 0 if no
  /// task is currently scheduled. Used by the deferred-pause loop to
  /// detect when its scheduling slot has been replaced.
  private var currentDeferredPauseGeneration: UInt64 {
    if case .scheduled(_, let generation) = deferredPause {
      generation
    } else {
      0
    }
  }

  /// Clears the `.issued` flag without cancelling a scheduled pause.
  /// Used when an external event (the user pressing play, the player
  /// settling into `.playing` on its own) makes the PiP-issued pause
  /// obsolete but we don't want to disturb a still-pending schedule.
  func clearIssuedPauseFlag() {
    if case .issued = deferredPause {
      deferredPause = .idle
    }
  }

  /// Returns whether PiP needs libVLC to resume, and whether the
  /// playback driver accepted the resume request. Checks both the
  /// `.issued` state (PiP actually paused libVLC) and the player's
  /// own resume hint.
  func requestResumeIfNeeded() -> (needed: Bool, accepted: Bool) {
    let pipIssuedPause = if case .issued = deferredPause {
      true
    } else {
      false
    }
    let shouldResume = pipIssuedPause || playbackDriver.shouldResume()
    if pipIssuedPause {
      deferredPause = .idle
    }
    guard shouldResume else { return (needed: false, accepted: false) }
    return (needed: true, accepted: playbackDriver.resume())
  }
}

#endif
