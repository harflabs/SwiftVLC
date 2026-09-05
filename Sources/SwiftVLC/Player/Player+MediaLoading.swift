import CLibVLC

extension Player {
  // MARK: - Media Loading

  /// Loads media into the player, replacing whatever was previously loaded.
  ///
  /// `media` is declared `sending`, so callers can construct a ``Media``
  /// on any actor or task and hand it off to this main-actor method
  /// without a copy. The compiler enforces the transfer: the caller
  /// cannot keep using the transferred reference after the call.
  public func load(_ media: sending Media) {
    // A shut-down player is inert: adopting media here would attach it to the
    // retiring handle's inert replacement and publish a `currentMedia` the
    // player can never play.
    guard !isShutdown else { return }
    subtitleTextBridge.reset(
      awaitingNativeClear: hasLiveNativeOutputForTextSubtitleReset
    )

    // A native PiP output copies the handle/playback identity before Swift is
    // told that the vout exists. Once a drawable-hosted handle may have opened
    // an output, assigning new media on that same pointer would retrospectively
    // relabel a delayed predecessor as the new playback generation. Stop the
    // retiring input, adopt the new media in Swift, and leave native assignment
    // to `prepareDrawableForPlayback()`, which installs it on a fresh handle.
    let defersNativeMediaUntilFreshHandle = nativeHandleMayHaveHostedOutput

    // Any recast still restoring the outgoing session no longer owns it.
    sessionGeneration = eventBridge.synchronizePlaybackGeneration(
      sessionGeneration &+ 1,
      media: media.pointer,
      outgoingNativeHandleGeneration: defersNativeMediaUntilFreshHandle
        ? eventBridge.currentNativeHandleGeneration
        : nil,
      expectRetiringHandleStopped: defersNativeMediaUntilFreshHandle
    )
    let mediaPublicationGeneration = sessionGeneration
    self.mediaPublicationGeneration = mediaPublicationGeneration
    defer {
      if self.mediaPublicationGeneration == mediaPublicationGeneration {
        self.mediaPublicationGeneration = nil
      }
    }

    #if os(iOS)
    let rejectedNativePiPIdentity: Bool
    if defersNativeMediaUntilFreshHandle {
      rejectedNativePiPIdentity = false
    } else {
      // A pristine handle has never exposed this identity to a vout, so its
      // generation may still be committed immediately before setting media.
      // Resolve this before publishing any successor state: if the v9 native
      // side rejects the identity, observers must see a dormant successor on
      // their very first synchronous callback.
      let didPublishPiPIdentity = Self.publishNativePiPPlaybackIdentity(
        on: pointer,
        playbackGeneration: sessionGeneration,
        nativeHandleIdentity: nativeHandleLifetime.nativePiPHandleIdentity
      )
      rejectedNativePiPIdentity = Self.nativePiPHandoffV9Available
        && !didPublishPiPIdentity
    }
    #else
    let rejectedNativePiPIdentity = false
    #endif
    guard ownsMediaPublication(mediaPublicationGeneration) else { return }

    let awaitsFreshNativeHandle = defersNativeMediaUntilFreshHandle
      || rejectedNativePiPIdentity
    if awaitsFreshNativeHandle {
      // Observation callbacks are synchronous and run before their triggering
      // mutation body. Establish the fail-closed identity invariant before
      // `currentMedia`, track resets, timeline resets, or any other B-visible
      // publication can reenter a native control and redirect it to A.
      nativePlayerNeedsReplacementBeforePlayback = true
      needsDrawableRebindForPlayback = true
      nativePlayerReplacementHasCommittedMediaGeneration = true
    }

    if defersNativeMediaUntilFreshHandle {
      prepareToStopNativePlayerForMediaReplacement()
      guard ownsMediaPublication(mediaPublicationGeneration) else { return }
    }

    guard
      publishCurrentMedia(
        media,
        playbackGeneration: mediaPublicationGeneration
      ) else { return }
    sessionGenerationMedia = media.pointer
    playbackControlIntent = nil
    guard
      resetMediaDerivedState(
        ifPlaybackGeneration: mediaPublicationGeneration
      ) else { return }

    if defersNativeMediaUntilFreshHandle {
      // The generation transaction above already froze the outgoing outcome
      // as `.replacement`. Issue only the native teardown now; routing through
      // public `stop()` would overwrite that causal reason with
      // `.requestedStop` for what is merely a PiP-safety implementation step.
      libvlc_media_player_stop_async(pointer)
    } else if !rejectedNativePiPIdentity {
      libvlc_media_player_set_media(pointer, media.pointer)
    }

    guard
      publishPlaybackState(
        .idle,
        ifPlaybackGeneration: mediaPublicationGeneration
      ) else { return }
    _ = notifyMediaDependentObservables(
      ifPlaybackGeneration: mediaPublicationGeneration
    )
  }

  /// Publishes `currentMedia` only if this exact load still owns the playback
  /// generation when Observation enters the mutation body. `onChange` runs
  /// before that body and may synchronously commit a newer nested load.
  func publishCurrentMedia(
    _ media: Media,
    playbackGeneration: UInt64
  ) -> Bool {
    withMutation(keyPath: \.currentMedia) {
      guard ownsMediaPublication(playbackGeneration) else { return false }
      currentMediaStorage = media
      return true
    }
  }

  func ownsMediaPublication(_ playbackGeneration: UInt64) -> Bool {
    mediaPublicationGeneration == playbackGeneration
      && sessionGeneration == playbackGeneration
      && eventBridge.currentPlaybackGeneration == playbackGeneration
  }

  /// Revalidates an observable mutation owned by one playback generation.
  /// A wrapper load additionally requires its still-live publication token;
  /// sourced native events run without that token but must still match both
  /// the adopted and callback-lane generations.
  func ownsPlaybackMutation(_ playbackGeneration: UInt64) -> Bool {
    guard
      sessionGeneration == playbackGeneration,
      eventBridge.currentPlaybackGeneration == playbackGeneration
    else { return false }
    guard let mediaPublicationGeneration else { return true }
    return mediaPublicationGeneration == playbackGeneration
  }

  /// Exact transaction identity for work which has already crossed into one
  /// native player. Playback generation alone is insufficient during recast:
  /// the generation can remain stable while the native handle is replaced.
  func ownsPlaybackMutation(
    _ playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64
  ) -> Bool {
    nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
      && ownsPlaybackMutation(playbackGeneration)
  }

  /// Runs an observable write only if its originating native/load transaction
  /// still owns the identity *after* Observation's synchronous `onChange`
  /// callbacks return and immediately before the synthesized setter body.
  @discardableResult
  func performObservableMutation(
    keyPath: KeyPath<Player, some Any>,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64?,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil,
    mutation: () -> Void
  ) -> Bool {
    func stillOwnsMutation() -> Bool {
      if let expectedTimelineRevision {
        guard expectedTimelineRevision == acceptedTimelineRevision else { return false }
      }
      if let expectedLifecycleControlEpoch {
        guard expectedLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
          return false
        }
      }
      if let expectedNativeHandleGeneration {
        guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
          return false
        }
      }
      guard let expectedPlaybackGeneration else { return true }
      return ownsPlaybackMutation(expectedPlaybackGeneration)
    }

    var didPerform = false
    withMutation(keyPath: keyPath) {
      guard stillOwnsMutation() else { return }
      mutation()
      didPerform = true
    }
    return didPerform && stillOwnsMutation()
  }

  /// Whether this exact native handle may already have published an output
  /// identity. Every signal is deliberately one-way/fail-closed: a delayed
  /// state or vout callback may under-report activity, but no positive signal
  /// is cleared until the handle itself is replaced.
  var nativeHandleMayHaveHostedOutput: Bool {
    guard nativePlayerHasHostedDrawable else { return false }
    if
      nativePlayerHasStartedPlayback
      || nativePlayerNeedsReplacementBeforePlayback
      || activeVideoOutputs > 0 {
      return true
    }

    switch state {
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      return true
    case .idle, .stopped:
      break
    }

    switch nativePlaybackState {
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      return true
    case .idle, .stopped:
      return false
    }
  }

  /// Performs the synchronous control cleanup shared with an explicit stop,
  /// but deliberately does not install an explicit-stop barrier or terminal
  /// intent. `load(_:)` immediately commits the replacement generation before
  /// issuing native stop, which makes `.replacement` the immutable outcome.
  private func prepareToStopNativePlayerForMediaReplacement() {
    supersedePendingSeekSettlement()
    resetNativeSeekMonitorForCausalBoundary()
    cancelPendingFrameSteps()
    if shouldResumeNativePlayerBeforeStop {
      swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(
        pointer,
        0
      )
    }
    pauseTransition = nil
    deferredPauseCommand = nil
    playbackControlIntent = nil
    clearManagedAudioSuspensionForExplicitControl()
    publishPlaybackIntent(false)
  }
}
