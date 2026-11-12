import CLibVLC

extension Player {
  /// Records a transition against an explicit generation. The explicit form
  /// is required while a MediaListPlayer's callback lane is ahead of the main
  /// actor's adopted `sessionGeneration`.
  func setPauseTransition(
    _ transition: PauseTransition?,
    playbackGeneration: UInt64
  ) {
    pauseTransition = transition
    pauseTransitionPlaybackGeneration = transition == nil ? nil : playbackGeneration
  }

  /// Records a deferred command without recapturing a newer callback-lane
  /// generation when an older command is retried.
  func setDeferredPauseCommand(
    _ command: DeferredPauseCommand?,
    playbackGeneration: UInt64
  ) {
    deferredPauseCommand = command
    deferredPauseCommandPlaybackGeneration = command == nil ? nil : playbackGeneration
  }

  nonisolated static func pauseDecisionState(
    cached: PlayerState,
    native: PlayerState,
    hasAttachedMediaListPlayer: Bool,
    callbackLaneIsAhead: Bool,
    mediaListPlaybackActive: Bool = false
  ) -> PlayerState {
    guard hasAttachedMediaListPlayer else { return cached }
    // The cached state can describe the outgoing item both before and after
    // `.mediaChanged` is adopted: the consumer deliberately yields before it
    // handles the successor's queued state event. Prefer the native state in
    // either window. When the callback lane is already on the successor but
    // its shared handle is still idle, treat that startup gap as opening so a
    // pause is retained for the new generation instead of being dropped.
    if
      callbackLaneIsAhead || mediaListPlaybackActive,
      native == .idle || native == .stopped {
      // The list player can report active before its shared media-player
      // handle leaves a non-active state. This signal remains authoritative
      // after the main actor adopts `.mediaChanged`, when the generation
      // comparison alone no longer identifies the startup gap.
      return .opening
    }
    // Otherwise retain an active cached state only for the narrow native
    // `.idle` gap where the shared handle momentarily trails the observable
    // state without either authoritative playlist-startup signal above.
    if native != .idle || cached == .idle || cached == .stopped {
      return native
    }
    return cached
  }

  /// Revalidates a playback generation after a native probe. A fresh user or
  /// PiP pause follows the media that is current when the probe completes;
  /// retrying an older deferred command stays bound to its original media and
  /// is cancelled if the callback lane has already advanced.
  nonisolated static func revalidatedPauseGeneration(
    captured: UInt64,
    current: UInt64,
    followsCurrentGeneration: Bool
  ) -> UInt64? {
    guard captured != current else { return captured }
    return followsCurrentGeneration ? current : nil
  }

  /// Pauses playback.
  ///
  /// If libVLC is visually playing but has not yet reached a stable,
  /// pausable state, SwiftVLC keeps the pause request pending and issues
  /// it once the native player reports that pausing is safe. With real
  /// audio output, the first audio timestamp must also have advanced
  /// beyond zero; pausing before that point can leave libVLC's aout
  /// stream with stale pause timing.
  public func pause() {
    guard !isShutdown else { return }
    _ = issuePause()
  }

  /// Resumes playback from pause.
  public func resume() {
    guard !isShutdown else { return }
    _ = issueResume(authorizesPlaybackAfterMediaServicesReset: true)
  }

  /// Toggles between playing and paused, or starts playback from an
  /// idle or stopped state. Pause requests during opening or buffering
  /// are queued until libVLC reaches a stable pausable state. No-op in
  /// terminal or invalid transient states (`.stopping`, `.error`).
  ///
  /// Dispatches through explicit pause/resume requests using the
  /// observed ``state`` and the current playback intent, rather than
  /// calling `libvlc_media_player_pause` (which is itself a toggle). The
  /// raw toggle is unsafe mid-transition: interleaving a pause-toggle
  /// with the audio output's opening path corrupts
  /// `stream->timing.pause_date` and trips the upstream assertion
  /// `stream->timing.pause_date == VLC_TICK_INVALID` in
  /// `src/audio_output/dec.c:876`, killing the process. This can happen
  /// when a user taps Play/Pause immediately after a
  /// `.task { try? player.play(url:) }` begins.
  public func togglePlayPause() {
    guard !isShutdown else { return }
    switch state {
    case .idle, .stopped:
      try? play()
    case .playing, .opening, .buffering, .paused:
      if isPlaybackRequestedActive {
        pause()
      } else {
        resume()
      }
    case .stopping, .error:
      // There is no stable playback target for a pause/resume command.
      break
    }
  }

  /// Issues a native pause owned by managed audio lifecycle while keeping the
  /// user's active playback intent published. Deferred pauses count as owned:
  /// foreground recovery must be able to cancel them before they settle.
  @discardableResult
  func issueManagedAudioPause(
    playbackGeneration requestedGeneration: UInt64? = nil
  ) -> Bool {
    guard
      isPlaybackRequestedActive,
      nativeHandleRepresentsCurrentMedia
    else { return false }
    preservesPlaybackIntentForManagedAudioSuspension = true
    let issued = issuePause(
      playbackGeneration: requestedGeneration,
      recordsPlaybackControlIntent: false
    )
    guard nativeHandleRepresentsCurrentMedia else {
      preservesPlaybackIntentForManagedAudioSuspension = false
      return false
    }
    publishPlaybackIntent(true)
    let ownsPause = issued
      || pauseTransition == .pausing
      || deferredPauseCommand == .pause
      || state == .paused
      || nativePlaybackState == .paused
    if !ownsPause {
      preservesPlaybackIntentForManagedAudioSuspension = false
    }
    return ownsPause
  }

  @discardableResult
  func issueManagedAudioResume() -> Bool {
    guard nativeHandleRepresentsCurrentMedia else { return false }
    let accepted = issueResume(recordsPlaybackControlIntent: false)
    guard nativeHandleRepresentsCurrentMedia else { return false }
    if accepted {
      preservesPlaybackIntentForManagedAudioSuspension = false
    }
    return accepted
  }

  @discardableResult
  func issuePause(
    playbackGeneration requestedGeneration: UInt64? = nil,
    recordsPlaybackControlIntent: Bool = true
  ) -> Bool {
    guard nativeHandleRepresentsCurrentMedia else { return false }
    if recordsPlaybackControlIntent {
      clearManagedAudioSuspensionForExplicitControl()
    }
    let followsCurrentGeneration = requestedGeneration == nil
    let previousPlaybackControlIntent = playbackControlIntent
    if recordsPlaybackControlIntent {
      playbackControlIntent = .pause
    }
    var playbackGeneration = requestedGeneration ?? eventBridge.currentPlaybackGeneration

    // A playlist can advance again while the main actor is probing the shared
    // native handle. Retry a bounded number of times to obtain a coherent
    // generation/state/capability snapshot. If rapid advancement never
    // stabilizes, retain the fresh request for the newest generation instead
    // of spinning on the main actor or dropping it.
    for probeAttempt in 0..<3 {
      guard nativeHandleRepresentsCurrentMedia else { return false }
      let generationBeforeProbe = eventBridge.currentPlaybackGeneration
      guard
        let revalidatedGeneration = Self.revalidatedPauseGeneration(
          captured: playbackGeneration,
          current: generationBeforeProbe,
          followsCurrentGeneration: followsCurrentGeneration
        )
      else {
        rollbackBoundPauseIntentIfNeeded(
          recordsPlaybackControlIntent: recordsPlaybackControlIntent,
          followsCurrentGeneration: followsCurrentGeneration,
          previousPlaybackControlIntent: previousPlaybackControlIntent
        )
        return false
      }
      playbackGeneration = revalidatedGeneration

      guard pauseTransition == nil else {
        retainDeferredPause(
          playbackGeneration: playbackGeneration,
          followsCurrentGeneration: followsCurrentGeneration
        )
        return false
      }

      // A MediaListPlayer drives this same native handle directly. Its native
      // state can therefore advance before the event bridge has published the
      // corresponding observable state on the main actor. Reconcile that lag
      // before deciding an apparently idle player cannot be paused.
      let listPlayer = attachedMediaListPlayer
      let hasAttachedMediaListPlayer = listPlayer != nil
      let nativeState = nativePlaybackState
      let mediaListPlaybackActive = listPlayer?.isPlaying == true
      #if DEBUG
      _pauseProbeHookForTesting?(.state)
      #endif
      let generationAfterStateProbe = eventBridge.currentPlaybackGeneration
      guard
        let generationAfterStateProbe = Self.revalidatedPauseGeneration(
          captured: playbackGeneration,
          current: generationAfterStateProbe,
          followsCurrentGeneration: followsCurrentGeneration
        )
      else {
        rollbackBoundPauseIntentIfNeeded(
          recordsPlaybackControlIntent: recordsPlaybackControlIntent,
          followsCurrentGeneration: followsCurrentGeneration,
          previousPlaybackControlIntent: previousPlaybackControlIntent
        )
        return false
      }
      if generationAfterStateProbe != playbackGeneration {
        playbackGeneration = generationAfterStateProbe
        if probeAttempt < 2 {
          continue
        }
        retainDeferredPause(
          playbackGeneration: playbackGeneration,
          followsCurrentGeneration: followsCurrentGeneration
        )
        return false
      }

      let isAheadOfAdoptedMedia = hasAttachedMediaListPlayer
        && playbackGeneration != sessionGeneration
      let effectiveState = Self.pauseDecisionState(
        cached: state,
        native: nativeState,
        hasAttachedMediaListPlayer: hasAttachedMediaListPlayer,
        callbackLaneIsAhead: isAheadOfAdoptedMedia,
        mediaListPlaybackActive: mediaListPlaybackActive
      )
      switch effectiveState {
      case .playing:
        break
      case .opening, .buffering:
        retainDeferredPause(
          playbackGeneration: playbackGeneration,
          followsCurrentGeneration: followsCurrentGeneration
        )
        return false
      case .paused:
        if
          deferredPauseCommand == .resume,
          deferredPauseCommandPlaybackGeneration == playbackGeneration {
          deferredPauseCommand = nil
        }
        publishPauseIntent()
        return false
      default:
        if recordsPlaybackControlIntent {
          #if DEBUG
          _pauseProbeHookForTesting?(.pauseRollback)
          #endif
          let didRestorePreviousIntent: Bool
          if followsCurrentGeneration {
            didRestorePreviousIntent = eventBridge.performIfCurrentPlaybackGeneration(
              playbackGeneration
            ) {
              playbackControlIntent = previousPlaybackControlIntent
            }
          } else {
            playbackControlIntent = previousPlaybackControlIntent
            didRestorePreviousIntent = true
          }
          if !didRestorePreviousIntent, followsCurrentGeneration {
            retainDeferredPause(
              playbackGeneration: playbackGeneration,
              followsCurrentGeneration: true
            )
          }
        }
        return false
      }

      // Keep this probe side-effect free until its generation is validated.
      // Refreshing observable capabilities here could publish values from a
      // successor under the outgoing media's generation.
      #if DEBUG
      let probedNativeCanPause = _nativeCanPauseOverrideForTesting
        ?? libvlc_media_player_can_pause(pointer)
      #else
      let probedNativeCanPause = libvlc_media_player_can_pause(pointer)
      #endif
      #if os(iOS) || os(macOS)
      let nativeCanPause = consumeQualificationNativeCanPauseOverride()
        ?? probedNativeCanPause
      #else
      let nativeCanPause = probedNativeCanPause
      #endif
      let nativePauseIsSafe = canIssueNativePause
      #if DEBUG
      _pauseProbeHookForTesting?(.capability)
      #endif
      let generationAfterCapabilityProbe = eventBridge.currentPlaybackGeneration
      guard
        let generationAfterCapabilityProbe = Self.revalidatedPauseGeneration(
          captured: playbackGeneration,
          current: generationAfterCapabilityProbe,
          followsCurrentGeneration: followsCurrentGeneration
        )
      else {
        rollbackBoundPauseIntentIfNeeded(
          recordsPlaybackControlIntent: recordsPlaybackControlIntent,
          followsCurrentGeneration: followsCurrentGeneration,
          previousPlaybackControlIntent: previousPlaybackControlIntent
        )
        return false
      }
      if generationAfterCapabilityProbe != playbackGeneration {
        playbackGeneration = generationAfterCapabilityProbe
        if probeAttempt < 2 {
          continue
        }
        retainDeferredPause(
          playbackGeneration: playbackGeneration,
          followsCurrentGeneration: followsCurrentGeneration
        )
        return false
      }
      guard nativeHandleRepresentsCurrentMedia else { return false }
      guard nativeCanPause, nativePauseIsSafe else {
        retainDeferredPause(
          playbackGeneration: playbackGeneration,
          followsCurrentGeneration: followsCurrentGeneration
        )
        return false
      }

      setPauseTransition(.pausing, playbackGeneration: playbackGeneration)
      if deferredPauseCommandPlaybackGeneration == playbackGeneration {
        deferredPauseCommand = nil
      }
      publishPauseIntent()
      let issuedPlaybackControlRevision = playbackControlIntentRevision
      guard nativeHandleRepresentsCurrentMedia else {
        clearPauseControlState(for: playbackGeneration)
        return false
      }
      libvlc_media_player_set_pause(pointer, 1)
      #if os(iOS) || os(macOS)
      recordQualificationNativePauseCommand()
      #endif
      #if DEBUG
      _pauseProbeHookForTesting?(.nativePause)
      #endif

      // Close the final check-to-command race. The native pause may already
      // have reached either side of the media boundary; retaining the request
      // for a newly observed successor guarantees the latest media still
      // settles paused after adoption clears the outgoing transition.
      let generationAfterPause = eventBridge.currentPlaybackGeneration
      if generationAfterPause != playbackGeneration {
        if followsCurrentGeneration {
          setDeferredPauseCommand(.pause, playbackGeneration: generationAfterPause)
          return true
        }

        // This request was deliberately bound to the captured media. The
        // callback lane can still advance in the few instructions between the
        // last check and `set_pause`. Undo a pause that may have reached the
        // successor, retire only the outgoing transition, and let the latest
        // persistent intent decide whether a fresh successor pause is queued.
        swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(
          pointer,
          0
        )
        clearPauseControlState(for: playbackGeneration)
        if recordsPlaybackControlIntent {
          playbackControlIntent = previousPlaybackControlIntent
        }
        if playbackControlIntent == .pause {
          setDeferredPauseCommand(.pause, playbackGeneration: generationAfterPause)
          publishPauseIntent()
        } else {
          publishPlaybackIntent(
            playbackControlIntent == .resume || state.isActive
          )
        }
        return false
      }
      lastIssuedPausePlaybackGeneration = playbackGeneration
      lastIssuedPausePlaybackControlRevision = issuedPlaybackControlRevision
      return true
    }
    return false
  }

  /// Stores a fresh pause against the newest callback-lane generation, while
  /// leaving an explicitly retried command bound to its original generation.
  private func retainDeferredPause(
    playbackGeneration: UInt64,
    followsCurrentGeneration: Bool
  ) {
    let generation = followsCurrentGeneration
      ? eventBridge.currentPlaybackGeneration
      : playbackGeneration
    setDeferredPauseCommand(.pause, playbackGeneration: generation)
    publishPauseIntent()
  }

  /// A fresh command can be generation-bound (PiP debounce) without following
  /// later media. If that bound is already stale, restore the transport intent
  /// that existed before the command; retries do not own that global intent.
  private func rollbackBoundPauseIntentIfNeeded(
    recordsPlaybackControlIntent: Bool,
    followsCurrentGeneration: Bool,
    previousPlaybackControlIntent: DeferredPauseCommand?
  ) {
    guard recordsPlaybackControlIntent, !followsCurrentGeneration else { return }
    playbackControlIntent = previousPlaybackControlIntent
    let intendsActivePlayback = switch previousPlaybackControlIntent {
    case .pause: false
    case .resume: true
    case nil: state.isActive
    }
    publishPlaybackIntent(intendsActivePlayback)
  }

  @discardableResult
  func issueResume(
    playbackGeneration requestedGeneration: UInt64? = nil,
    recordsPlaybackControlIntent: Bool = true,
    authorizesPlaybackAfterMediaServicesReset: Bool = false
  ) -> Bool {
    guard nativeHandleRepresentsCurrentMedia else { return false }
    // Every accepted public/AVKit Resume must remain an engine-visible
    // command. The first attempt can clear Swift's intent quarantine while
    // native AVAudioSession activation still fails and retains its own latch;
    // a later user retry must therefore cross the same boundary again.
    let issuesExplicitNativeResumeCommand = authorizesPlaybackAfterMediaServicesReset
    if recordsPlaybackControlIntent {
      clearManagedAudioSuspensionForExplicitControl()
    }
    let followsCurrentGeneration = requestedGeneration == nil
    let previousPlaybackControlIntent = playbackControlIntent
    if followsCurrentGeneration {
      playbackControlIntent = .resume
    }
    var playbackGeneration = requestedGeneration ?? eventBridge.currentPlaybackGeneration

    for probeAttempt in 0..<3 {
      guard nativeHandleRepresentsCurrentMedia else { return false }
      let generationBeforeProbe = eventBridge.currentPlaybackGeneration
      guard
        let revalidatedGeneration = Self.revalidatedPauseGeneration(
          captured: playbackGeneration,
          current: generationBeforeProbe,
          followsCurrentGeneration: followsCurrentGeneration
        )
      else { return false }
      playbackGeneration = revalidatedGeneration
      let nativeHandleGeneration = eventBridge.currentNativeHandleGeneration

      guard pauseTransition == nil else {
        let generation = followsCurrentGeneration
          ? eventBridge.currentPlaybackGeneration
          : playbackGeneration
        setDeferredPauseCommand(.resume, playbackGeneration: generation)
        acceptExplicitResumeCommand(
          issuesExplicitNativeResumeCommand,
          issuesNativeResumeCommand: true
        )
        if issuesExplicitNativeResumeCommand, pauseTransition == .pausing {
          // The native resume above is queued behind the pause it answers.
          // libVLC defers a pause requested while it is buffering and reports
          // nothing when a resume cancels it, so waiting for `.paused` here
          // would leave the transition open for the rest of the media and
          // turn every later pause into a deferred command that never runs.
          // The deferred resume stays recorded: if the pause did apply, its
          // `.paused` event finds this resume still owed instead of
          // publishing an inactive intent between the two native events.
          pauseTransition = nil
        }
        publishPlaybackIntent(true)
        prepareForPlaybackResumeBoundary()
        return true
      }

      let nativeState = nativePlaybackState
      #if DEBUG
      _pauseProbeHookForTesting?(.resumeState)
      #endif
      let generationAfterProbe = eventBridge.currentPlaybackGeneration
      guard
        let generationAfterProbe = Self.revalidatedPauseGeneration(
          captured: playbackGeneration,
          current: generationAfterProbe,
          followsCurrentGeneration: followsCurrentGeneration
        )
      else { return false }
      if generationAfterProbe != playbackGeneration {
        playbackGeneration = generationAfterProbe
        if probeAttempt < 2 {
          continue
        }
        setDeferredPauseCommand(.resume, playbackGeneration: playbackGeneration)
        acceptExplicitResumeCommand(
          issuesExplicitNativeResumeCommand,
          issuesNativeResumeCommand: true
        )
        publishPlaybackIntent(true)
        prepareForPlaybackResumeBoundary()
        return true
      }
      guard
        nativeHandleRepresentsCurrentMedia,
        nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
      else { return false }

      if
        deferredPauseCommand == .pause,
        deferredPauseCommandPlaybackGeneration == playbackGeneration {
        deferredPauseCommand = nil
        if nativeState != .paused {
          if
            retainDeferredResumeIfPlaybackIsStillSettling(
              nativeState: nativeState,
              playbackGeneration: playbackGeneration
            ) {
            acceptExplicitResumeCommand(
              issuesExplicitNativeResumeCommand,
              issuesNativeResumeCommand: true
            )
            publishPlaybackIntent(true)
            prepareForPlaybackResumeBoundary()
            return true
          }
          acceptExplicitResumeCommand(
            issuesExplicitNativeResumeCommand,
            issuesNativeResumeCommand: true
          )
          publishPlaybackIntent(true)
          prepareForPlaybackResumeBoundary()
          return true
        }
      }

      guard nativeState == .paused else {
        if
          retainDeferredResumeIfPlaybackIsStillSettling(
            nativeState: nativeState,
            playbackGeneration: playbackGeneration
          ) {
          acceptExplicitResumeCommand(
            issuesExplicitNativeResumeCommand,
            issuesNativeResumeCommand: true
          )
          publishPlaybackIntent(true)
          prepareForPlaybackResumeBoundary()
          return true
        }
        if state == .paused, nativeState.isActive {
          if playbackGeneration == sessionGeneration {
            guard
              publishPlaybackState(
                nativeState,
                ifPlaybackGeneration: playbackGeneration,
                nativeHandleGeneration: nativeHandleGeneration
              )
            else { return false }
          }
          acceptExplicitResumeCommand(
            issuesExplicitNativeResumeCommand,
            issuesNativeResumeCommand: true
          )
          guard
            publishPlaybackIntent(
              true,
              ifPlaybackGeneration: playbackGeneration == sessionGeneration
                ? playbackGeneration
                : nil,
              nativeHandleGeneration: nativeHandleGeneration
            )
          else { return false }
          prepareForPlaybackResumeBoundary()
          return true
        }
        if state.isActive, state != .paused {
          acceptExplicitResumeCommand(
            issuesExplicitNativeResumeCommand,
            issuesNativeResumeCommand: true
          )
          publishPlaybackIntent(true)
          prepareForPlaybackResumeBoundary()
          return true
        }
        if followsCurrentGeneration {
          #if DEBUG
          _pauseProbeHookForTesting?(.resumeRollback)
          #endif
          let didRestorePreviousIntent = eventBridge.performIfCurrentPlaybackGeneration(
            playbackGeneration
          ) {
            playbackControlIntent = previousPlaybackControlIntent
          }
          if !didRestorePreviousIntent {
            setDeferredPauseCommand(
              .resume,
              playbackGeneration: eventBridge.currentPlaybackGeneration
            )
            publishPlaybackIntent(true)
          }
        }
        return false
      }

      acceptExplicitResumeCommand(
        issuesExplicitNativeResumeCommand,
        issuesNativeResumeCommand: false
      )
      prepareForPlaybackResumeBoundary()
      setPauseTransition(.resuming, playbackGeneration: playbackGeneration)
      if deferredPauseCommandPlaybackGeneration == playbackGeneration {
        deferredPauseCommand = nil
      }
      guard
        publishPlaybackIntent(
          true,
          ifPlaybackGeneration: playbackGeneration == sessionGeneration
            ? playbackGeneration
            : nil,
          nativeHandleGeneration: nativeHandleGeneration
        ),
        nativeHandleRepresentsCurrentMedia,
        playbackGeneration == eventBridge.currentPlaybackGeneration,
        nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
      else {
        clearPauseControlState(for: playbackGeneration)
        return false
      }
      issueNativeResumeCommand(
        authorizesPlaybackAfterMediaServicesReset:
        authorizesPlaybackAfterMediaServicesReset
      )

      if followsCurrentGeneration {
        let generationAfterResume = eventBridge.currentPlaybackGeneration
        if generationAfterResume != playbackGeneration {
          setDeferredPauseCommand(.resume, playbackGeneration: generationAfterResume)
        }
      }
      return true
    }
    return false
  }

  /// Completes the Swift half of an accepted post-reset Resume command. The
  /// native audio output has its own reset latch, so every accepted path must
  /// also cross an engine-visible command boundary even when libVLC still
  /// reports Playing/Opening and an ordinary resume would be optimized away.
  private func acceptExplicitResumeCommand(
    _ isRequired: Bool,
    issuesNativeResumeCommand: Bool
  ) {
    guard isRequired else { return }
    acknowledgeMediaServicesResetWithFreshPlaybackIntent()
    if issuesNativeResumeCommand {
      issueNativeResumeCommand(
        authorizesPlaybackAfterMediaServicesReset: true
      )
    }
  }

  private func issueNativeResumeCommand(
    authorizesPlaybackAfterMediaServicesReset: Bool
  ) {
    // The command can be deferred across native probes. Never let a callback
    // or synchronous observer-triggered load redirect it to a retiring handle.
    guard nativeHandleRepresentsCurrentMedia else { return }
    #if DEBUG
    if let override = _nativeResumeAuthorizationOverrideForTesting {
      override(authorizesPlaybackAfterMediaServicesReset)
      return
    }
    if let override = _nativeResumeCommandOverrideForTesting {
      override()
      return
    }
    #endif
    if authorizesPlaybackAfterMediaServicesReset {
      libvlc_media_player_set_pause(pointer, 0)
    } else {
      swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(
        pointer,
        0
      )
    }
  }

  /// Retires paused-only wrapper work before playback resumes. Ordinary
  /// resumed clock progress is not seek landing evidence, so an unresolved
  /// native seek keeps its single-flight lease until its watched terminal
  /// point or an actual timeline-replacement boundary arrives.
  func prepareForPlaybackResumeBoundary() {
    disablePendingPausedSeekFallback()
    cancelPendingFrameSteps()
    nativeSeekMonitor.clearFrameQuarantineForCausalBoundary()
  }

  /// How long an issued pause may stay unacknowledged while playback visibly
  /// continues before it is treated as lost.
  nonisolated static var pauseAcknowledgementTimeout: Duration {
    .seconds(1)
  }

  /// Retires a `.pausing` transition libVLC is never going to acknowledge.
  ///
  /// A pause produces a `.paused` event only when libVLC applies it. One that
  /// is dropped (the input refused it, or left the playing state first) or
  /// deferred behind buffering and then cancelled produces none, and an open
  /// transition makes every later pause a deferred command that waits on it.
  /// Called from playback-time updates: a clock that is still being reported
  /// while the native player says it is playing, this long after the pause was
  /// issued, is the evidence that no acknowledgement is coming. The latest
  /// intent is then re-issued, so a pause the user still wants is sent again
  /// (a repeat is harmless if libVLC is merely still buffering) and a resume
  /// recorded meanwhile simply completes.
  func retireUnacknowledgedPauseIfPlaybackContinues(
    now: ContinuousClock.Instant = .now
  ) {
    guard
      pauseTransition == .pausing,
      let playbackGeneration = pauseTransitionPlaybackGeneration,
      playbackGeneration == sessionGeneration,
      playbackGeneration == eventBridge.currentPlaybackGeneration,
      let beganAt = pauseTransitionBeganAt,
      beganAt.duration(to: now) >= Self.pauseAcknowledgementTimeout,
      nativePlaybackState == .playing
    else { return }
    pauseTransition = nil
    if deferredPauseCommand == nil {
      setDeferredPauseCommand(.pause, playbackGeneration: playbackGeneration)
    }
    performDeferredPauseCommandIfNeeded()
  }

  /// A resume observed while the successor is still opening is not complete:
  /// an earlier pause call may still settle after this probe. Keep the resume
  /// generation-scoped until native playback confirms either playing or
  /// paused, at which point the retry can finish or issue the unpause.
  private func retainDeferredResumeIfPlaybackIsStillSettling(
    nativeState: PlayerState,
    playbackGeneration: UInt64
  ) -> Bool {
    let listStartupIsActive = attachedMediaListPlayer?.isPlaying == true
    if
      nativeState == .opening || nativeState == .buffering
      || (listStartupIsActive && (nativeState == .idle || nativeState == .stopped)) {
      setDeferredPauseCommand(.resume, playbackGeneration: playbackGeneration)
      return true
    }
    return false
  }

  func cancelPendingPause(
    playbackGeneration: UInt64? = nil,
    playbackControlRevision: UInt64? = nil,
    restoringPlaybackControlIntent: DeferredPauseCommand = .resume
  ) {
    if let playbackControlRevision {
      guard playbackControlIntentRevision == playbackControlRevision else { return }

      // Exact command identity is stronger than the captured generation. A
      // playlist adoption can migrate the same retained command onto its
      // successor without changing this revision; requiring the obsolete
      // generation in that case leaves the PiP-owned pause live after the
      // controller has reported cancellation.
      let ownsPendingPause = deferredPauseCommand == .pause
      let ownsIssuedPause = didIssuePause(
        playbackGeneration: nil,
        playbackControlRevision: playbackControlRevision
      )
      guard ownsPendingPause || ownsIssuedPause else { return }

      if ownsPendingPause {
        deferredPauseCommand = nil
      }
      if ownsIssuedPause, restoringPlaybackControlIntent == .resume {
        // The event lane may already have sent the pause while the controller
        // slept. Queueing a resume through the normal state machine handles
        // both an in-flight `.pausing` transition and an already-paused input.
        _ = issueResume()
      } else {
        setPlaybackControlIntent(restoringPlaybackControlIntent)
      }
      return
    }

    guard deferredPauseCommand == .pause else { return }
    if let playbackGeneration {
      guard deferredPauseCommandPlaybackGeneration == playbackGeneration else { return }
    }
    deferredPauseCommand = nil
    setPlaybackControlIntent(restoringPlaybackControlIntent)
  }

  /// Whether an exact explicit pause reached the native player.
  ///
  /// Passing `nil` for `playbackGeneration` intentionally follows a command
  /// that playlist adoption migrated to a successor. The revision still has
  /// to be current, so an older PiP cleanup cannot classify or undo a newer
  /// app pause.
  func didIssuePause(
    playbackGeneration: UInt64?,
    playbackControlRevision: UInt64
  ) -> Bool {
    guard
      playbackControlIntentRevision == playbackControlRevision,
      lastIssuedPausePlaybackControlRevision == playbackControlRevision
    else { return false }
    if let playbackGeneration {
      return lastIssuedPausePlaybackGeneration == playbackGeneration
    }
    return true
  }

  /// Retires every pause/resume command when an external owner of the shared
  /// native handle accepts a stop. A stale deferred command must not survive
  /// until a later list adoption and become authoritative again.
  @discardableResult
  func clearPlaybackControlForExternalStop(
    establishesPlaybackBarrier: Bool = true,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    if establishesPlaybackBarrier {
      eventBridge.beginExplicitStopBarrier(
        playbackGeneration: expectedPlaybackGeneration
          ?? eventBridge.currentPlaybackGeneration
      )
    }
    pauseTransition = nil
    deferredPauseCommand = nil
    playbackControlIntent = nil
    clearManagedAudioSuspensionForExplicitControl()
    return publishPlaybackIntent(
      false,
      ifPlaybackGeneration: expectedPlaybackGeneration,
      nativeHandleGeneration: expectedNativeHandleGeneration,
      lifecycleControlEpoch: expectedLifecycleControlEpoch
    )
  }

  private func publishPauseIntent() {
    publishPlaybackIntent(preservesPlaybackIntentForManagedAudioSuspension)
  }

  func clearManagedAudioSuspensionForExplicitControl() {
    preservesPlaybackIntentForManagedAudioSuspension = false
    isManagedAudioLifecycleSuspended = false
    isManagedAudioMediaServicesSuspended = false
    isManagedAudioResumeDeniedByInterruption = false
    isManagedAudioResumePendingActivation = false
  }

  /// Installs the durable playback boundary required after the media server
  /// restarts. This is stronger than publishing `false` once: it retires any
  /// pre-reset resume work, records a pause that follows playlist adoption,
  /// and makes every later native active-state reconciliation remain inactive
  /// until an explicit playback-enabling API acknowledges the reset.
  func beginMediaServicesResetPlaybackQuarantine() {
    requiresFreshPlaybackIntentAfterMediaServicesReset = true
    // Mirror the revoked intent to the nonisolated AVKit snapshot first. The
    // remaining command cleanup is main-actor synchronous, but PiP state
    // queries can arrive concurrently on an arbitrary callback thread.
    publishPlaybackIntent(false)
    clearManagedAudioSuspensionForExplicitControl()
    if pauseTransition == .resuming {
      pauseTransition = nil
    }
    if deferredPauseCommand == .resume {
      deferredPauseCommand = nil
    }
    if playbackControlIntent != .pause {
      playbackControlIntent = .pause
    }
  }

  /// Marks a new, playback-enabling command as the user's post-reset action.
  /// Bare state/intent observations deliberately cannot call this method.
  func acknowledgeMediaServicesResetWithFreshPlaybackIntent() {
    requiresFreshPlaybackIntentAfterMediaServicesReset = false
  }
}
