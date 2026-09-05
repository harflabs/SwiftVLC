import CLibVLC
import Foundation

extension Player {
  // MARK: - Playback Control

  /// Loads media and starts playback in one step.
  /// - Throws: ``VLCError/playbackFailed(reason:)`` if playback cannot
  ///   start, or ``VLCError/operationFailed(_:)`` with `"Set renderer"` if a
  ///   selected renderer cannot be applied to a replacement native player.
  public func play(_ media: sending Media) throws(VLCError) {
    // Guarded here as well as in `play()`: the replacement branch below
    // creates a fresh native handle and video output before `play()` is ever
    // reached, which a shut-down player must never do.
    guard !isShutdown else {
      throw .invalidState("play(_:) called on a player that has been shut down")
    }
    if shouldReplaceNativePlayerBeforePlaybackLoad {
      let resumeBeforeRelease = shouldResumeNativePlayerBeforeStop
      let requestedPlaybackGeneration = PlaybackGeneration(sessionGeneration &+ 1)
      // Nothing is published until the native swap succeeds. Committing
      // `currentMedia` first meant a rejected renderer left every public
      // field describing the incoming media while the outgoing handle was
      // still playing the previous one.
      try replaceNativePlayerForDrawablePlayback(
        target: drawable,
        media: media,
        resumeBeforeRelease: resumeBeforeRelease,
        successorPlaybackGeneration: requestedPlaybackGeneration
      )
      let mediaPublicationGeneration = sessionGeneration
      precondition(
        mediaPublicationGeneration == requestedPlaybackGeneration.value,
        "Fresh-handle playback must commit its requested generation"
      )
      self.mediaPublicationGeneration = mediaPublicationGeneration
      defer {
        if self.mediaPublicationGeneration == mediaPublicationGeneration {
          self.mediaPublicationGeneration = nil
        }
      }
      guard
        publishCurrentMedia(
          media,
          playbackGeneration: mediaPublicationGeneration
        ) else { return }
      sessionGenerationMedia = media.pointer
      // No `notifyMediaDependentObservables()` here: the swap already issued
      // it, and the keypaths it refreshes read from the native handle rather
      // than from `currentMedia`, so a second pass is pure churn.
      playbackControlIntent = nil
      guard
        resetMediaDerivedState(
          ifPlaybackGeneration: mediaPublicationGeneration
        ) else { return }
      guard
        publishPlaybackState(
          .idle,
          ifPlaybackGeneration: mediaPublicationGeneration
        ) else { return }
    } else {
      load(media)
    }
    if let mediaPublicationGeneration {
      guard ownsMediaPublication(mediaPublicationGeneration) else { return }
      self.mediaPublicationGeneration = nil
    }
    try play()
  }

  /// Creates media from a direct media URL and starts playback.
  ///
  /// This does not expand playlist container URLs such as `.pls` or
  /// classic `.m3u`; use ``MediaListPlayer`` or resolve those files to
  /// an inner stream URL first. HLS `.m3u8` URLs are valid here because
  /// they are streaming manifests.
  /// - Throws: ``VLCError/mediaCreationFailed(source:)``,
  ///   ``VLCError/playbackFailed(reason:)``, or
  ///   ``VLCError/operationFailed(_:)`` with `"Set renderer"` if a selected
  ///   renderer cannot be applied to a replacement native player.
  public func play(url: URL) throws(VLCError) {
    try play(Media(url: url))
  }

  /// Starts playback.
  /// - Throws: ``VLCError/playbackFailed(reason:)`` if playback cannot
  ///   start, or ``VLCError/operationFailed(_:)`` with `"Set renderer"` if a
  ///   selected renderer cannot be applied to a replacement native player.
  public func play() throws(VLCError) {
    try startPlayback(recordsPlaybackControlIntent: true)
  }

  /// Starts the native transport, optionally treating it as a fresh public
  /// playback command.
  ///
  /// Internal handle restoration (notably recast) must sometimes make a new
  /// handle decode before restoring its timeline and physical pause state.
  /// That transport bootstrap is not a user Resume: it must not clear managed
  /// audio suspension, acknowledge a media-services reset, or overwrite the
  /// intent/revision that was captured before replacement.
  func startPlayback(
    recordsPlaybackControlIntent: Bool
  )
    throws(VLCError) {
    guard !isShutdown else {
      throw .invalidState("play() called on a player that has been shut down")
    }
    guard mediaPublicationGeneration == nil else {
      throw .invalidState("play() called while a media load is being published")
    }
    let establishesResumeBoundary = shouldResumeForExternalPlayRequest
    let replacementUsesCommittedMediaGeneration =
      nativePlayerReplacementHasCommittedMediaGeneration
    let nativeStateBeforePlay = nativePlaybackState
    let establishesColdPlaybackGeneration = nativePlayerHasStartedPlayback
      && !establishesResumeBoundary
      && !replacementUsesCommittedMediaGeneration
      && (nativeStateBeforePlay == .idle
        || nativeStateBeforePlay == .stopped
        || nativeStateBeforePlay == .error)
    let replacementPlaybackGeneration: PlaybackGeneration? =
      if nativePlayerNeedsReplacementBeforePlayback {
        if replacementUsesCommittedMediaGeneration {
          PlaybackGeneration(sessionGeneration)
        } else if establishesColdPlaybackGeneration {
          PlaybackGeneration(sessionGeneration &+ 1)
        } else {
          nil
        }
      } else {
        nil
      }
    let preparationPlaybackGeneration = sessionGeneration
    guard eventBridge.currentPlaybackGeneration == preparationPlaybackGeneration else {
      throw .invalidState("play() called while native media adoption is in progress")
    }
    if recordsPlaybackControlIntent {
      clearManagedAudioSuspensionForExplicitControl()
    }
    try prepareDrawableForPlayback(
      successorPlaybackGeneration: replacementPlaybackGeneration,
      playbackGenerationIsAlreadyCommitted:
      replacementUsesCommittedMediaGeneration
    )
    let expectedPreparedPlaybackGeneration = replacementPlaybackGeneration?.value
      ?? preparationPlaybackGeneration
    guard
      sessionGeneration == expectedPreparedPlaybackGeneration,
      eventBridge.currentPlaybackGeneration == expectedPreparedPlaybackGeneration
    else {
      // An observable replacement publication can synchronously start a newer
      // load. That nested transaction owns the player; this superseded Play
      // request must not continue against its handle.
      return
    }
    if establishesColdPlaybackGeneration, replacementPlaybackGeneration == nil {
      sessionGeneration = eventBridge.beginPlaybackGeneration(
        sessionGeneration &+ 1,
        media: currentMedia?.pointer
      )
      sessionGenerationMedia = currentMedia?.pointer
      retagCapabilitySnapshotForPlaybackGeneration()
      publishPlaybackStatus()
    } else if establishesColdPlaybackGeneration {
      // The replacement transaction already synchronized and published the
      // final generation before set_media could create its first output.
      retagCapabilitySnapshotForPlaybackGeneration()
      publishPlaybackStatus()
    }
    let playPlaybackGeneration = sessionGeneration
    let playNativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let playPointer = pointer
    func stillOwnsPlaybackStart() -> Bool {
      pointer == playPointer
        && nativeHandleRepresentsCurrentMedia
        && ownsPlaybackMutation(playPlaybackGeneration)
        && eventBridge.currentNativeHandleGeneration == playNativeHandleGeneration
    }
    guard stillOwnsPlaybackStart() else { return }
    guard
      performObservableMutation(
        keyPath: \.didReachEnd,
        ifPlaybackGeneration: playPlaybackGeneration,
        nativeHandleGeneration: playNativeHandleGeneration,
        mutation: {
          storeDidReachEndWithoutNestedObservation(false)
        }
      ) else { return }
    guard stillOwnsPlaybackStart() else { return }
    let playbackStartAttempt = eventBridge.beginPlaybackStartAttempt(
      playbackGeneration: playPlaybackGeneration
    )
    guard stillOwnsPlaybackStart() else {
      eventBridge.finishPlaybackStartAttempt(playbackStartAttempt, accepted: false)
      return
    }
    #if DEBUG
    let playResult = _nativePlayOverrideForTesting?() ?? libvlc_media_player_play(playPointer)
    #else
    let playResult = libvlc_media_player_play(playPointer)
    #endif
    eventBridge.finishPlaybackStartAttempt(
      playbackStartAttempt,
      accepted: playResult != -1
    )
    guard stillOwnsPlaybackStart() else { return }
    if playResult == -1 {
      if recordsPlaybackControlIntent {
        playbackControlIntent = nil
        guard
          publishPlaybackIntent(
            false,
            ifPlaybackGeneration: playPlaybackGeneration,
            nativeHandleGeneration: playNativeHandleGeneration
          ) else { return }
      }
      guard
        publishPlaybackState(
          Self.stateAfterRejectedStart(previous: state),
          ifPlaybackGeneration: playPlaybackGeneration,
          nativeHandleGeneration: playNativeHandleGeneration
        ) else { return }
      let reason = libvlc_errmsg().map { String(cString: $0) } ?? "unknown"
      throw .playbackFailed(reason: reason)
    }
    // A Play command becomes post-reset permission only after libVLC accepts
    // it. Rejected preparation or start attempts must leave the quarantine in
    // place so a late native callback cannot impersonate a successful retry.
    if recordsPlaybackControlIntent {
      acknowledgeMediaServicesResetWithFreshPlaybackIntent()
    }
    if establishesResumeBoundary {
      prepareForPlaybackResumeBoundary()
    }
    nativePlayerHasStartedPlayback = true
    if recordsPlaybackControlIntent {
      _ = setPlaybackControlIntent(
        .resume,
        ifPlaybackGeneration: playPlaybackGeneration,
        nativeHandleGeneration: playNativeHandleGeneration
      )
    }
  }

  /// Stops playback asynchronously.
  ///
  /// The native stop completes later, signalled by the
  /// `.stateChanged(.stopped)` event — use ``stopAndWait()`` when
  /// teardown must not race the audio/video output drain (for example
  /// before deactivating a shared `AVAudioSession`).
  public func stop() {
    _ = requestPlaybackStop()
  }

  /// Reserves one exact Stop episode before entering native code.
  ///
  /// Stop clears observable playback intent, and Observation callbacks can
  /// synchronously issue a newer Play/Resume/load. Capturing only the native
  /// pointer before that publication is insufficient: the same pointer can
  /// host the successor. This reservation establishes callback quarantine,
  /// publishes the stopped intent, then revalidates every causal identity.
  func reservePlaybackStop(
    establishesPlaybackBarrier: Bool
  ) -> PlayerPlaybackStopReservation? {
    let requestedPointer = pointer
    let requestedNativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let requestedPlaybackGeneration = eventBridge.currentPlaybackGeneration
    if
      let reservation = reservePlaybackStopOnce(
        establishesPlaybackBarrier: establishesPlaybackBarrier
      ) {
      return reservation
    }

    // Publishing the stopped intent can synchronously invoke a nested Play.
    // A rejected Play advances the lifecycle epoch, then restores the Stop
    // barrier. In that case the original Stop remains the newest accepted
    // transport command and must be re-reserved against the restored epoch.
    // An accepted Play clears the barrier, so it wins and this retry is
    // deliberately skipped. The second pass cannot re-trigger the same
    // observer because the rejected start already restored inactive intent.
    guard
      establishesPlaybackBarrier,
      pointer == requestedPointer,
      eventBridge.currentNativeHandleGeneration == requestedNativeHandleGeneration,
      eventBridge.currentPlaybackGeneration == requestedPlaybackGeneration,
      eventBridge.hasExplicitStopBarrier(
        playbackGeneration: requestedPlaybackGeneration
      ),
      playbackControlIntent == nil,
      !isPlaybackRequestedActive
    else { return nil }
    return reservePlaybackStopOnce(establishesPlaybackBarrier: true)
  }

  private func reservePlaybackStopOnce(
    establishesPlaybackBarrier: Bool
  ) -> PlayerPlaybackStopReservation? {
    guard !isShutdown else { return nil }
    supersedePendingSeekSettlement()
    // Stop is an explicit terminal boundary. Rotate the watch attachment so
    // an in-flight seek callback from the stopped input cannot consume a token
    // accepted by a later playback session on this same handle.
    resetNativeSeekMonitorForCausalBoundary()
    cancelPendingFrameSteps()
    let stopPointer = pointer
    let stopNativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let stopPlaybackGeneration = eventBridge.currentPlaybackGeneration
    let nativeStateBeforeStop = nativeHandlePlaybackState
    let resumesBeforeStop = shouldResumeNativePlayerBeforeStop

    // For an active handle, `beginRequestedStopBarrier` establishes both the callback
    // barrier and requested cause in one callback-ordering critical section.
    // Splitting those calls lets a concurrently natural MediaStopping freeze
    // its cause in the gap. A settled handle needs only the barrier.
    if establishesPlaybackBarrier {
      switch nativeStateBeforeStop {
      case .idle, .stopped, .error:
        eventBridge.beginExplicitStopBarrier(
          playbackGeneration: stopPlaybackGeneration
        )
      case .opening, .buffering, .playing, .paused, .stopping:
        eventBridge.beginRequestedStopBarrier(
          playbackGeneration: stopPlaybackGeneration
        )
      }
    }
    let stopLifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch

    guard
      clearPlaybackControlForExternalStop(
        establishesPlaybackBarrier: false,
        ifPlaybackGeneration: stopPlaybackGeneration,
        nativeHandleGeneration: stopNativeHandleGeneration,
        lifecycleControlEpoch: stopLifecycleControlEpoch
      )
    else { return nil }
    let stopPlaybackControlRevision = playbackControlIntentRevision
    let episode = PlayerPlaybackStopEpisode(
      nativeHandleGeneration: stopNativeHandleGeneration,
      playbackGeneration: stopPlaybackGeneration,
      lifecycleControlEpoch: stopLifecycleControlEpoch,
      playbackControlRevision: stopPlaybackControlRevision,
      requiresExplicitStopBarrier: establishesPlaybackBarrier
    )
    guard pointer == stopPointer, ownsPlaybackStopEpisode(episode) else { return nil }

    if nativePlayerHasHostedDrawable {
      nativePlayerNeedsReplacementBeforePlayback = true
      needsDrawableRebindForPlayback = true
    } else {
      needsDrawableRebindForPlayback = drawable != nil
    }
    return PlayerPlaybackStopReservation(
      nativePlayer: stopPointer,
      episode: episode,
      resumesBeforeStop: resumesBeforeStop
    )
  }

  /// Whether no newer native, media, or transport-control episode has taken
  /// ownership since `episode` was reserved.
  func ownsPlaybackStopEpisode(_ episode: PlayerPlaybackStopEpisode) -> Bool {
    guard
      !isShutdown,
      eventBridge.currentNativeHandleGeneration == episode.nativeHandleGeneration,
      eventBridge.currentPlaybackGeneration == episode.playbackGeneration,
      eventBridge.currentLifecycleControlEpoch == episode.lifecycleControlEpoch,
      playbackControlIntentRevision == episode.playbackControlRevision
    else { return false }
    return !episode.requiresExplicitStopBarrier
      || eventBridge.hasExplicitStopBarrier(
        playbackGeneration: episode.playbackGeneration
      )
  }

  /// Dispatches an already-reserved Stop and returns its exact wait identity.
  @discardableResult
  func dispatchPlaybackStop(
    _ reservation: PlayerPlaybackStopReservation
  ) -> PlayerPlaybackStopEpisode? {
    guard preparePlaybackStopForExternalDispatch(reservation) else { return nil }
    #if DEBUG
    if let _nativeStopOverrideForTesting {
      _nativeStopOverrideForTesting()
    } else {
      libvlc_media_player_stop_async(reservation.nativePlayer)
    }
    #else
    libvlc_media_player_stop_async(reservation.nativePlayer)
    #endif
    guard
      pointer == reservation.nativePlayer,
      ownsPlaybackStopEpisode(reservation.episode)
    else { return nil }
    return reservation.episode
  }

  /// Completes any paused-output preparation while retaining the reservation
  /// for an external owner such as `MediaListPlayer`, which must dispatch its
  /// own list-level Stop rather than `libvlc_media_player_stop_async`.
  func preparePlaybackStopForExternalDispatch(
    _ reservation: PlayerPlaybackStopReservation
  ) -> Bool {
    guard
      pointer == reservation.nativePlayer,
      ownsPlaybackStopEpisode(reservation.episode)
    else { return false }
    if reservation.resumesBeforeStop {
      swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(
        reservation.nativePlayer,
        0
      )
    }
    return pointer == reservation.nativePlayer
      && ownsPlaybackStopEpisode(reservation.episode)
  }

  /// Reserves and dispatches the public Stop against the currently attached
  /// native handle. A dormant drawable successor deliberately stops only its
  /// retiring handle and must not stamp the unplayed successor with a stop
  /// barrier or requested terminal cause.
  @discardableResult
  func requestPlaybackStop() -> PlayerPlaybackStopEpisode? {
    subtitleTextBridge.reset(
      awaitingNativeClear: hasLiveNativeOutputForTextSubtitleReset
    )
    let stopsRetiringHandleForDormantSuccessor = nativePlayerNeedsReplacementBeforePlayback
      && nativePlayerReplacementHasCommittedMediaGeneration
    guard
      let reservation = reservePlaybackStop(
        establishesPlaybackBarrier: !stopsRetiringHandleForDormantSuccessor
      )
    else { return nil }
    return dispatchPlaybackStop(reservation)
  }
}
