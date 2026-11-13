import CLibVLC
import os
import Synchronization

extension Player {
  // MARK: - Media-derived state reset

  /// Resets the observable state that depends on the current media —
  /// times, duration, seek/pause flags, buffer fill. Called when media
  /// is loaded or replaced.
  @discardableResult
  func resetMediaDerivedState(
    preservingPlaybackIntent: Bool = false,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    var resetTimelineRevision: UInt64?
    func stillOwnsReset() -> Bool {
      if let resetTimelineRevision {
        guard resetTimelineRevision == acceptedTimelineRevision else { return false }
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

    guard stillOwnsReset() else { return false }
    supersedePendingSeekSettlement()
    cancelPendingFrameSteps()
    resetNativeSeekMonitorForCausalBoundary()
    // New media, new timeline: clock samples still queued from the previous
    // one describe a media that is no longer loaded and must not be applied.
    let revision = eventBridge.advanceTimelineRevision()
    acceptedTimelineRevision = revision
    resetTimelineRevision = revision
    // `duration` and `isSeekable` publish the capability snapshot from their
    // own `didSet`, so clearing them one at a time would briefly expose
    // "duration cleared, seekability still the previous media's". Suppress
    // those partial publishes and emit one atomic snapshot below.
    isSuppressingCapabilityPublish = true
    defer { isSuppressingCapabilityPublish = false }
    if
      let pauseTransitionPlaybackGeneration,
      pauseTransitionPlaybackGeneration < sessionGeneration {
      pauseTransition = nil
    }
    // A native MediaListPlayer can advance the event bridge and accept a
    // pause for a later item before queued media-change events reach the main
    // actor. Preserve current and future commands through each adoption;
    // commands from an older media generation are still retired.
    if
      let deferredPauseCommandPlaybackGeneration,
      deferredPauseCommandPlaybackGeneration < sessionGeneration {
      deferredPauseCommand = nil
    }
    // A deferred command was requested after the in-flight transition, so it
    // is the latest user intent and wins when both survive adoption.
    let intendsActivePlayback = if preservingPlaybackIntent {
      isPlaybackRequestedActive
    } else {
      switch deferredPauseCommand {
      case .pause: false
      case .resume: true
      case nil: pauseTransition == .resuming
      }
    }
    guard
      publishPlaybackIntent(
        intendsActivePlayback,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      ) else { return false }
    // Track ids and selection flags belong to one native input session. Keep
    // no outgoing entries visible while a replacement parses its own lists:
    // doing so lets restoration code mistake stale non-empty arrays for proof
    // that the successor is ready, then dispatch ids which are meaningless on
    // the new handle.
    guard
      performObservableMutation(
        keyPath: \.audioTracks,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          removeAllAudioTrackStorageWithoutNestedObservation()
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.videoTracks,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          removeAllVideoTrackStorageWithoutNestedObservation()
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.subtitleTracks,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          removeAllSubtitleTrackStorageWithoutNestedObservation()
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.selectedAudioTrack,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {}
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.selectedSubtitleTrack,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {}
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.currentTime,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeCurrentTimeWithoutNestedObservation(.zero)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.duration,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeDurationWithoutNestedObservation(nil)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.isSeekable,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeSeekableWithoutNestedObservation(false)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.isPausable,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storePausableWithoutNestedObservation(false)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.bufferFill,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeBufferFillWithoutNestedObservation(0)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.activeVideoOutputs,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeActiveVideoOutputsWithoutNestedObservation(0)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.position,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          _position = 0
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.didReachEnd,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeDidReachEndWithoutNestedObservation(false)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.failure,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeFailureWithoutNestedObservation(nil)
        }
      ) else { return false }
    guard stillOwnsReset(), let resetTimelineRevision else { return false }
    eventBridge.updateAuthoritativeTimeline(
      time: .zero,
      position: 0,
      playbackGeneration: expectedPlaybackGeneration ?? sessionGeneration,
      timelineRevision: resetTimelineRevision
    )
    guard stillOwnsReset() else { return false }
    // New media, new capability generation. The bump and the reset values are
    // written under one lock acquisition, so a reader can never see the new
    // generation carrying the outgoing media's capability — which would make
    // it distrust the poll for the rest of that media's lifetime.
    advanceCapabilityGeneration()
    guard
      resetPlaybackHealth(
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: resetTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      ) else { return false }
    return stillOwnsReset()
  }

  /// Re-applies the latest user intent to a media generation advanced by the
  /// native callback lane. This is the authoritative close for a media switch
  /// that occurs after `pause()` or `resume()` performs its final generation
  /// read: adoption cannot clear the intent or leave the successor untouched.
  func reconcilePauseControlAfterExternalMediaAdoption(
    playbackGeneration: UInt64,
    command: DeferredPauseCommand
  ) {
    guard !hasPauseControl(after: playbackGeneration) else { return }
    setDeferredPauseCommand(command, playbackGeneration: playbackGeneration)
    performDeferredPauseCommandIfNeeded()
  }

  /// Signals every observable whose value is read live from libVLC and can
  /// change when a new media is loaded. Most have no standalone native event;
  /// rate-resolution events require extension v7 and do not replace the media
  /// boundary refresh. SwiftUI could otherwise keep showing the pre-swap
  /// value. Empty `withMutation` calls force the getters to re-run next frame.
  @discardableResult
  func notifyMediaDependentObservables(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    func stillOwnsNotification() -> Bool {
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

    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.rate) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.audioDelay) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.subtitleDelay) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.subtitleTextScale) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.role) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.stereoMode) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.mixMode) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.teletextPage) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.currentChapter) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.currentTitle) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.abLoopState) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.programs) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.selectedProgram) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.isProgramScrambled) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.currentAudioDevice) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.selectedAudioTrack) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.selectedSubtitleTrack) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.videoSize) {}
    guard stillOwnsNotification() else { return false }
    withMutation(keyPath: \.hasVideoOutput) {}
    return stillOwnsNotification()
  }

  /// Reads length / seekable / pausable directly from libVLC and
  /// publishes any changes to the matching observable property. Called
  /// on state transitions and early time updates as a resilient companion
  /// to `MediaPlayerLengthChanged` / `SeekableChanged` /
  /// `PausableChanged`, which are not guaranteed to fire on the player's
  /// event manager for every media.
  @discardableResult
  func refreshNativeStateIfNeeded(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    // An unsourced manual refresh is still one exact transaction. Resolving
    // defaults here prevents an Observation callback from replacing the
    // media/handle and then letting the older sampled values publish into the
    // successor merely because the caller passed nil identities.
    let sourcePlaybackGeneration = expectedPlaybackGeneration ?? sessionGeneration
    let sourceNativeHandleGeneration = expectedNativeHandleGeneration
      ?? eventBridge.currentNativeHandleGeneration
    let sourceTimelineRevision = expectedTimelineRevision ?? acceptedTimelineRevision
    let sourceLifecycleControlEpoch = expectedLifecycleControlEpoch
      ?? eventBridge.currentLifecycleControlEpoch

    func sourceIsCurrent() -> Bool {
      guard
        sourcedEventIdentityIsCurrent(
          nativeHandleGeneration: sourceNativeHandleGeneration,
          playbackGeneration: sourcePlaybackGeneration
        ) else { return false }
      guard sourceTimelineRevision == acceptedTimelineRevision else { return false }
      guard sourceLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
        return false
      }
      return true
    }

    func performControlRefreshMutation(
      keyPath: KeyPath<Player, some Any>,
      revision revisionKeyPath: WritableKeyPath<PlayerIntentRevisions, UInt64>,
      expectedRevision: UInt64,
      mutation: () -> Void
    ) -> Bool {
      func stillOwnsMutation() -> Bool {
        sourceIsCurrent()
          && intentRevisions[keyPath: revisionKeyPath] == expectedRevision
      }

      var didPerform = false
      withMutation(keyPath: keyPath) {
        guard stillOwnsMutation() else { return }
        mutation()
        didPerform = true
      }
      return didPerform && stillOwnsMutation()
    }

    guard sourceIsCurrent() else { return false }
    if duration == nil {
      #if DEBUG
      let ms = _nativeLengthOverrideForTesting ?? libvlc_media_player_get_length(pointer)
      #else
      let ms = libvlc_media_player_get_length(pointer)
      #endif
      if ms > 0 {
        guard
          performObservableMutation(
            keyPath: \.duration,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: sourceTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storeDurationWithoutNestedObservation(.milliseconds(ms))
            }
          ) else { return false }
      }
    }

    guard sourceIsCurrent() else { return false }
    #if DEBUG
    let nativeSeekable = _nativeSeekableOverrideForTesting
      ?? libvlc_media_player_is_seekable(pointer)
    #else
    let nativeSeekable = libvlc_media_player_is_seekable(pointer)
    #endif
    if isSeekable != nativeSeekable {
      guard
        performObservableMutation(
          keyPath: \.isSeekable,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: sourceTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storeSeekableWithoutNestedObservation(nativeSeekable)
          }
        ) else { return false }
    }

    guard sourceIsCurrent() else { return false }
    let nativePausable = libvlc_media_player_can_pause(pointer)
    if isPausable != nativePausable {
      guard
        performObservableMutation(
          keyPath: \.isPausable,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: sourceTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storePausableWithoutNestedObservation(nativePausable)
          }
        ) else { return false }
    }

    // libVLC reports volume/mute via `libvlc_audio_get_volume` and
    // `libvlc_audio_get_mute`; both return negative sentinels (observed
    // as `-100` and `-1` respectively on libVLC 4.0) when the audio
    // output isn't initialized yet. Only sync the shadow state from
    // valid (non-negative) reads.
    guard sourceIsCurrent() else { return false }
    let volumeRevision = intentRevisions.audioVolume
    #if DEBUG
    let nativeVolume = _nativeVolumeOverrideForTesting ?? libvlc_audio_get_volume(pointer)
    #else
    let nativeVolume = libvlc_audio_get_volume(pointer)
    #endif
    if nativeVolume >= 0 {
      let normalized = Float(nativeVolume) / 100.0
      if abs(_volume - normalized) > 0.001 {
        guard
          performControlRefreshMutation(
            keyPath: \.volume,
            revision: \PlayerIntentRevisions.audioVolume,
            expectedRevision: volumeRevision,
            mutation: {
              _volume = normalized
            }
          ) else { return false }
      }
    }

    guard sourceIsCurrent() else { return false }
    let muteRevision = intentRevisions.mute
    #if DEBUG
    let nativeMute = _nativeMuteOverrideForTesting ?? libvlc_audio_get_mute(pointer)
    #else
    let nativeMute = libvlc_audio_get_mute(pointer)
    #endif
    if nativeMute >= 0 {
      let muted = nativeMute > 0
      if _isMuted != muted {
        guard
          performControlRefreshMutation(
            keyPath: \.isMuted,
            revision: \PlayerIntentRevisions.mute,
            expectedRevision: muteRevision,
            mutation: {
              _isMuted = muted
            }
          ) else { return false }
      }
    }
    return sourceIsCurrent()
  }

  /// Re-reads the current media from libVLC, wrapping the C pointer in
  /// a fresh `Media` value if one is now attached. Called when libVLC
  /// emits `MediaChanged` (for media swaps initiated from a list
  /// player, etc.).
  @discardableResult
  func syncCurrentMediaFromNative(
    sourcePlaybackGeneration: UInt64? = nil,
    sourceNativeHandleGeneration: UInt64? = nil
  ) -> Bool {
    let media = libvlc_media_player_get_media(pointer).map(Media.init(retaining:))
    return withMutation(keyPath: \.currentMedia) {
      guard
        sourcedEventIdentityIsCurrent(
          nativeHandleGeneration: sourceNativeHandleGeneration,
          playbackGeneration: sourcePlaybackGeneration,
          allowsUnadoptedPlaybackGeneration: true
        ) else { return false }
      currentMediaStorage = media
      return true
    }
  }

  func _handleEventForTesting(_ event: PlayerEvent) {
    handleEvent(event)
  }

  /// Injects an event attributed to a native-handle generation, so tests can
  /// exercise the scoping in ``handleSourcedEvent(_:)``.
  ///
  /// Staging the attribution is the point: a retiring handle emitting after
  /// its replacement is a race, not something a test can schedule.
  func _handleEventForTesting(_ event: PlayerEvent, nativeHandleGeneration: UInt64) {
    handleSourcedEvent(
      SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: sessionGeneration,
        event: event
      )
    )
  }

  func _hasDeferredPauseForTesting() -> Bool {
    deferredPauseCommand == .pause
  }

  func _setStateForTesting(
    state: PlayerState? = nil,
    nativeState: PlayerState? = nil,
    isPlaybackRequestedActive: Bool? = nil,
    currentTime: Duration? = nil,
    duration: Duration? = nil,
    position: Double? = nil,
    isSeekable: Bool? = nil,
    isPausable: Bool? = nil
  ) {
    if let state {
      self.state = state
      #if DEBUG
      _nativePlaybackStateOverrideForTesting = nativeState ?? state
      #endif
      publishPlaybackIntent(state.isActive)
    }
    #if DEBUG
    if state == nil, let nativeState {
      _nativePlaybackStateOverrideForTesting = nativeState
    }
    #else
    _ = nativeState
    #endif
    if let isPlaybackRequestedActive {
      publishPlaybackIntent(isPlaybackRequestedActive)
    }
    if let currentTime {
      self.currentTime = currentTime
    }
    if let duration {
      self.duration = duration
    }
    if let position {
      _position = position
    }
    if let isSeekable {
      self.isSeekable = isSeekable
    }
    if let isPausable {
      self.isPausable = isPausable
    }
  }
}
