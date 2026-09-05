import CLibVLC
import os
import Synchronization

/// Event consumer that mirrors native player signals onto `Player`'s
/// `@Observable` properties, plus the deferred-pause / playback-intent
/// reconciliation state machine.
extension Player {
  /// Publishes every mirror fed by a duration mutation, including values
  /// learned from the fallback native poll rather than an event callback.
  func didUpdateDuration() {
    publishCapabilitySnapshot()
    eventBridge.updateKnownDuration(duration, playbackGeneration: sessionGeneration)
  }

  // MARK: - Native state probes

  /// libVLC's view of the player state — read directly from the
  /// underlying handle, not the asynchronously updated ``state`` mirror.
  ///
  /// Use this for transport decisions that must account for a native stop,
  /// pause, or resume before its event reaches the main actor. Prefer
  /// ``state`` for observation-driven UI because this synchronous snapshot is
  /// not itself observable. Returns `.idle` while a newly loaded media is
  /// waiting for its fresh native handle; the still-attached handle belongs to
  /// the retiring media and is not a valid native snapshot of ``currentMedia``.
  public var nativePlaybackState: PlayerState {
    guard nativeHandleRepresentsCurrentMedia else { return .idle }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readNativePlaybackState)
    #endif
    return nativeHandlePlaybackState
  }

  /// Raw state of the attached pointer, including a retiring handle during a
  /// deferred media replacement. Only lifecycle teardown may use this value;
  /// media-specific public controls must use the identity-checked property.
  var nativeHandlePlaybackState: PlayerState {
    #if DEBUG
    if let _nativePlaybackStateOverrideForTesting {
      return _nativePlaybackStateOverrideForTesting
    }
    #endif
    return PlayerState(from: libvlc_media_player_get_state(pointer))
  }

  /// Whether issuing `set_pause(1)` right now is safe with respect to
  /// libVLC's audio-output state machine.
  ///
  /// With a real audio output, libVLC can report `.playing` and
  /// pausable before the first audio timestamp has cleared zero. Pausing
  /// in that window leaves the aout stream with a stale pause date and
  /// the next audio block trips libVLC's debug assertion. When audio
  /// is disabled or not initialized, libVLC reports a negative volume
  /// sentinel and no aout stream participates in that assertion.
  var canIssueNativePause: Bool {
    #if DEBUG
    if let _nativePauseSafetyOverrideForTesting {
      return _nativePauseSafetyOverrideForTesting
    }
    #endif
    if libvlc_media_player_get_time(pointer) > 0 {
      return true
    }
    return libvlc_audio_get_volume(pointer) < 0
  }

  // MARK: - Event consumer task

  /// Spawns the signal-consuming `Task` that mirrors libVLC events
  /// onto observable properties. Captures `eventBridge` strongly and
  /// `self` weakly to avoid the retain cycle Player → eventTask → Player.
  ///
  /// The subscription is unbounded: `state` and every other mirrored
  /// property must not skip a transition just because the main actor
  /// lagged behind a burst. The cost is that during active playback the
  /// buffer grows at full event rate (the ~30 Hz `timeChanged`/
  /// `positionChanged` firehose) for as long as the main actor is
  /// stalled — small enum payloads, proportional to stall duration. A
  /// main actor stalled long enough for that to matter is already a
  /// broken app; a lossy buffer here would instead leave the observable
  /// mirror permanently wrong about a one-shot transition.
  func startEventConsumer() {
    let bridge = eventBridge
    let stream = bridge.makeSourcedPlayerSignalStream(policy: .unbounded)
    eventTask = Task { [weak self] in
      for await signal in stream {
        guard !Task.isCancelled else { return }
        self?.handleSourcedPlayerSignal(signal)
        // Yield after each event so other main-actor work (UI updates,
        // tests, etc.) isn't starved when VLC produces events rapidly.
        await Task.yield()
      }
    }
  }

  /// Dispatches one value from the private ordered native-signal lane.
  func handleSourcedPlayerSignal(_ signal: SourcedPlayerSignal) {
    switch signal {
    case .event(let sourcedEvent):
      handleSourcedEvent(sourcedEvent)
    case .effectivePlaybackRateResolution(let resolution):
      handleEffectivePlaybackRateResolution(resolution)
    }
  }

  /// Invalidates the observable native-rate getter only for the exact handle
  /// and media session that emitted the resolution. Rate and ordinary events
  /// share one private ordered signal lane, so a preceding media change is
  /// adopted before its rate resolution reaches this check.
  func handleEffectivePlaybackRateResolution(
    _ resolution: EffectivePlaybackRateResolution
  ) {
    guard
      resolution.nativeGeneration == eventBridge.currentNativePlayerGeneration,
      resolution.playbackGeneration == PlaybackGeneration(sessionGeneration)
    else { return }
    // The payload is exposed on the public resolution stream, while the
    // observable getter re-reads the same authoritative native control state.
    withMutation(keyPath: \Player.rate) {}
  }

  // MARK: - handleEvent dispatch

  func handleSourcedEvent(_ sourcedEvent: SourcedPlayerEvent) {
    guard
      sourcedEvent.nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
    else { return }
    if case .mediaChanged = sourcedEvent.event {
      guard sourcedEvent.playbackGeneration >= sessionGeneration else { return }
      #if os(iOS)
      if
        sourcedEvent.playbackGeneration > sessionGeneration,
        let attachment = drawable as? IOSNativePiPDrawableAttachment {
        // List navigation can reuse the live vout, whose immutable v9 output
        // identity still names the previous media. Retire PiP before exposing
        // the externally adopted generation. A wrapper-initiated echo equals
        // `sessionGeneration` and intentionally skips this path.
        attachment.failClosedForSameHandleMediaChange(
          nativeHandle: nativeHandleLifetime.nativePiPHandleIdentity
        )
      }
      #endif
      handleEvent(
        sourcedEvent.event,
        sourcePlaybackGeneration: sourcedEvent.playbackGeneration,
        sourceNativeHandleGeneration: sourcedEvent.nativeHandleGeneration,
        sourceLifecycleControlEpoch: sourcedEvent.lifecycleControlEpoch
      )
      return
    }
    guard sourcedEvent.playbackGeneration == sessionGeneration else { return }
    guard isLifecycleControlEventCurrent(sourcedEvent) else { return }
    guard isTimelineSampleCurrent(sourcedEvent) else { return }
    guard !quarantineSeekTimelineSampleIfNeeded(sourcedEvent) else { return }
    let expectedTimelineRevision = acceptedTimelineRevision
    if
      case .timeChanged = sourcedEvent.event,
      let stamp = sourcedEvent.nativeSeekEmissionStamp {
      commitNativeTimelineEmission(stamp.timelineEmissionSequence)
    } else if
      case .positionChanged = sourcedEvent.event,
      let stamp = sourcedEvent.nativeSeekEmissionStamp {
      commitNativeTimelineEmission(stamp.timelineEmissionSequence)
    }
    handleEvent(
      sourcedEvent.event,
      sourcePlaybackGeneration: sourcedEvent.playbackGeneration,
      sourceNativeHandleGeneration: sourcedEvent.nativeHandleGeneration,
      expectedTimelineRevision: expectedTimelineRevision,
      sourceLifecycleControlEpoch: sourcedEvent.lifecycleControlEpoch
    )
    guard
      sourcedEventIdentityIsCurrent(
        nativeHandleGeneration: sourcedEvent.nativeHandleGeneration,
        playbackGeneration: sourcedEvent.playbackGeneration
      ),
      expectedTimelineRevision == acceptedTimelineRevision,
      (sourcedEvent.lifecycleControlEpoch.map {
        $0 == eventBridge.currentLifecycleControlEpoch
      } ?? true)
    else { return }
    switch sourcedEvent.event {
    case .timeChanged, .positionChanged:
      recordAuthoritativeTimeline(
        position: position,
        emissionSequence: sourcedEvent.nativeSeekEmissionStamp?
          .timelineEmissionSequence,
        ifPlaybackGeneration: sourcedEvent.playbackGeneration,
        nativeHandleGeneration: sourcedEvent.nativeHandleGeneration,
        timelineRevision: expectedTimelineRevision,
        lifecycleControlEpoch: sourcedEvent.lifecycleControlEpoch
      )
    default:
      break
    }
  }

  /// Same-generation native state can still be stale across Stop/Play because
  /// libVLC delivers callbacks asynchronously. Real bridge events carry the
  /// control epoch frozen at callback entry; directly-constructed unit events
  /// omit it and preserve their historical behavior.
  private func isLifecycleControlEventCurrent(
    _ sourcedEvent: SourcedPlayerEvent
  ) -> Bool {
    let isActiveStateEvidence = switch sourcedEvent.event {
    case .stateChanged(let state):
      switch state {
      case .opening, .buffering, .playing, .paused:
        true
      case .idle, .stopped, .stopping, .error:
        false
      }
    case .bufferingProgress:
      true
    default:
      false
    }
    guard isActiveStateEvidence else { return true }
    guard let lifecycleControlEpoch = sourcedEvent.lifecycleControlEpoch else {
      return true
    }
    guard lifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
      return false
    }
    return !eventBridge.hasExplicitStopBarrier(
      playbackGeneration: sourcedEvent.playbackGeneration
    )
  }

  /// Whether a clock sample still describes the authoritative timeline.
  ///
  /// The internal stream is unbounded, so time and position events produced
  /// before a seek can still be sitting in it when the seek is accepted.
  /// Applying them afterwards snaps the published time back to where playback
  /// used to be — and while paused there may be no later native clock event to
  /// repair it. Samples that predate the accepted seek are therefore dropped.
  ///
  /// Only clock payloads are filtered. State transitions, track changes and
  /// the rest stay lossless regardless of when they were produced.
  private func isTimelineSampleCurrent(_ sourcedEvent: SourcedPlayerEvent) -> Bool {
    switch sourcedEvent.event {
    case .timeChanged, .positionChanged:
      guard
        let stamp = sourcedEvent.nativeSeekEmissionStamp
      else {
        // Directly-constructed unit events retain their historical revision-
        // only semantics. Every real EventBridge callback carries a stamp.
        return sourcedEvent.timelineRevision >= acceptedTimelineRevision
      }
      return stamp.timelineGeneration == nativeSeekMonitor.timelineGeneration
        && stamp.externalEpoch == nativeSeekMonitor.externalSeekEpoch
        && !stamp.externalDrainPending
        && !stamp.externalOverlapAmbiguous
        && canCommitNativeTimelineEmission(stamp.timelineEmissionSequence)
        && (
          sourcedEvent.timelineRevision >= acceptedTimelineRevision
            || stamp.timelineEmissionSequence > acceptedNativeTimelineEmissionSequence
        )
    default:
      return true
    }
  }

  /// Maps a single `PlayerEvent` to the observable-property updates and
  /// state-machine transitions it implies. Called from
  /// `startEventConsumer`'s loop on every event the bridge yields.
  func handleEvent(
    _ event: PlayerEvent,
    sourcePlaybackGeneration: UInt64? = nil,
    sourceNativeHandleGeneration: UInt64? = nil,
    expectedTimelineRevision: UInt64? = nil,
    sourceLifecycleControlEpoch: UInt64? = nil
  ) {
    let interval = Signposts.signposter.beginInterval("Player.handleEvent")
    defer { Signposts.signposter.endInterval("Player.handleEvent", interval) }
    func sourceIsCurrent(allowsUnadoptedPlaybackGeneration: Bool = false) -> Bool {
      guard
        sourcedEventIdentityIsCurrent(
          nativeHandleGeneration: sourceNativeHandleGeneration,
          playbackGeneration: sourcePlaybackGeneration,
          allowsUnadoptedPlaybackGeneration: allowsUnadoptedPlaybackGeneration
        ) else { return false }
      if let expectedTimelineRevision {
        guard expectedTimelineRevision == acceptedTimelineRevision else { return false }
      }
      if let sourceLifecycleControlEpoch {
        guard sourceLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
          return false
        }
      }
      return true
    }

    switch event {
    case .stateChanged(let newState):
      let previousState = state
      guard
        publishPlaybackState(
          newState,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      if previousState == .paused, newState == .playing {
        prepareForPlaybackResumeBoundary()
      }
      guard sourceIsCurrent() else { return }
      switch newState {
      case .stopped, .error:
        // A bare `play()` can publish a new active intent before this
        // same-generation terminal event drains from the main-actor queue.
        // The native subtitle output emits its ordered clear on teardown; only
        // mirror a clear here when no successor playback has already begun.
        if !isPlaybackRequestedActive {
          subtitleTextBridge.reset()
        }
        supersedeSeekWorkForTerminalBoundary()
        cancelPendingFrameSteps()
      case .idle, .stopping:
        supersedeSeekWorkForTerminalBoundary()
        cancelPendingFrameSteps()
      case .opening, .buffering, .playing, .paused:
        break
      }
      guard sourceIsCurrent() else { return }
      updatePauseTransition(for: newState)
      guard sourceIsCurrent() else { return }
      guard
        reconcilePlaybackIntent(
          for: newState,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      guard sourceIsCurrent() else { return }
      if case .stopped = newState {
        guard
          performObservableMutation(
            keyPath: \.currentTime,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: expectedTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storeCurrentTimeWithoutNestedObservation(.zero)
            }
          ) else { return }
        guard
          performObservableMutation(
            keyPath: \.bufferFill,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: expectedTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storeBufferFillWithoutNestedObservation(0)
            }
          ) else { return }
        guard
          performObservableMutation(
            keyPath: \.position,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: expectedTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storePositionWithoutNestedObservation(0)
            }
          ) else { return }
        guard
          performObservableMutation(
            keyPath: \.abLoopState,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: expectedTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {}
          ) else { return }
      }
      // libVLC doesn't always emit `MediaPlayerLengthChanged`,
      // `MediaPlayerSeekableChanged`, or `MediaPlayerPausableChanged`
      // events on the player side. For some inputs the demuxer publishes
      // those via `MediaParsedChanged` on `Media` (which we don't bridge
      // to the player), or sets the fields before the player has a
      // chance to attach its event listener. Polling on every state
      // transition catches those cases. It's three C calls and is
      // idempotent when the events do fire.
      guard
        refreshNativeStateIfNeeded(
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: expectedTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      performDeferredPauseCommandIfNeeded()
      guard sourceIsCurrent() else { return }
      if case .paused = newState {
        dispatchNextPendingFrameStepIfNeeded()
      }

    case .timeChanged(let time):
      guard
        performObservableMutation(
          keyPath: \.currentTime,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: expectedTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storeCurrentTimeWithoutNestedObservation(time)
          }
        ) else { return }
      if duration == nil || !isSeekable || !isPausable {
        guard
          refreshNativeStateIfNeeded(
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: expectedTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch
          ) else { return }
      }
      performDeferredPauseCommandIfNeeded()

    case .positionChanged(let pos):
      guard
        performObservableMutation(
          keyPath: \.position,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: expectedTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storePositionWithoutNestedObservation(pos)
          }
        ) else { return }

    case .lengthChanged(let length):
      if isSuppressingRawCapabilityEvents {
        suppressedRawLengthEventCount += 1
      } else {
        guard
          performObservableMutation(
            keyPath: \.duration,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storeDurationWithoutNestedObservation(length)
            }
          ) else { return }
      }

    case .seekableChanged(let seekable):
      if isSuppressingRawCapabilityEvents {
        suppressedRawSeekableEventCount += 1
      } else {
        guard
          performObservableMutation(
            keyPath: \.isSeekable,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storeSeekableWithoutNestedObservation(seekable)
            }
          ) else { return }
      }

    case .pausableChanged(let pausable):
      guard
        performObservableMutation(
          keyPath: \.isPausable,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storePausableWithoutNestedObservation(pausable)
          }
        ) else { return }
      performDeferredPauseCommandIfNeeded()

    case .tracksChanged:
      let previousVideoTracks = videoTracks
      guard
        refreshTracks(
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: expectedTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      if Self.playbackHealthVideoTracksDiffer(previousVideoTracks, videoTracks) {
        guard
          markPlaybackHealthAdaptiveSwitch(
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            timelineRevision: expectedTimelineRevision,
            lifecycleControlEpoch: sourceLifecycleControlEpoch
          ) else { return }
      }
      guard sourceIsCurrent() else { return }
      // Adaptive streams can switch resolution mid-stream without any
      // dedicated size event; libVLC reports the change through the
      // track list (ES selection/update), so re-signal the decoded
      // size here for observers to re-read. `hasVideoOutput` is a
      // selected-track probe over the same data, so it is track-driven
      // too.
      withMutation(keyPath: \.videoSize) {}
      guard sourceIsCurrent() else { return }
      withMutation(keyPath: \.hasVideoOutput) {}

    case .mediaChanged:
      guard
        publishExternalMediaReplacementBoundaryIfNeeded(
          successorPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        )
      else { return }
      let previousSessionGeneration = sessionGeneration
      let playbackControlIntent = playbackControlIntent
      guard
        syncCurrentMediaFromNative(
          sourcePlaybackGeneration: sourcePlaybackGeneration,
          sourceNativeHandleGeneration: sourceNativeHandleGeneration
        ) else { return }
      let changedMediaIdentity = currentMedia?.pointer != sessionGenerationMedia
      // A media change the wrapper did not initiate still has to supersede
      // whatever was restoring the previous session: a `MediaListPlayer`
      // advancing the list calls `libvlc_media_list_player_next` directly, so
      // `load(_:)` never runs and nothing else advances the generation.
      // EventBridge distinguishes the wrapper's expected echo from an
      // externally initiated change and stamps the authoritative generation.
      // That remains correct even when a playlist intentionally reuses the
      // exact same retained media pointer for consecutive sessions.
      if
        let sourcePlaybackGeneration,
        sourcePlaybackGeneration > sessionGeneration {
        sessionGeneration = sourcePlaybackGeneration
        sessionGenerationMedia = currentMedia?.pointer
        publishPlaybackStatus()
      } else if changedMediaIdentity {
        if sourcePlaybackGeneration == nil {
          sessionGeneration = eventBridge.synchronizePlaybackGeneration(
            sessionGeneration &+ 1,
            media: currentMedia?.pointer
          )
        }
        sessionGenerationMedia = currentMedia?.pointer
        // The state has not changed, so `publishPlaybackState` will not run:
        // without this the status would keep reporting the old session.
        publishPlaybackStatus()
      }
      guard sourceIsCurrent() else { return }
      let adoptedExternalGeneration = sessionGeneration > previousSessionGeneration
      let carriesPlaybackControl = adoptedExternalGeneration && playbackControlIntent != nil
      // `load(_:)` establishes the new generation and resets its timeline
      // before calling `set_media`. The resulting native MediaChanged echo is
      // stamped with that already-adopted generation, but can remain queued
      // while a same-turn seek is accepted. Resetting on the echo would then
      // supersede that valid seek and rotate away its native monitor token.
      // Events without source attribution retain the conservative legacy
      // behavior; sourced external changes always advance or replace identity.
      let replacedTimeline = adoptedExternalGeneration
        || changedMediaIdentity
        || sourcePlaybackGeneration == nil
      if replacedTimeline {
        // `load(_:)` clears synchronously. Native-driven list advancement
        // tears down the outgoing subtitle output, which emits an ordered
        // empty callback. Avoid a late main-actor reset after a successor cue
        // has already arrived.
        if !isPlaybackRequestedActive {
          subtitleTextBridge.reset()
        }
        guard
          resetMediaDerivedState(
            preservingPlaybackIntent: carriesPlaybackControl,
            ifPlaybackGeneration: sessionGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            lifecycleControlEpoch: sourceLifecycleControlEpoch
          ) else { return }
      }
      guard sourceIsCurrent() else { return }
      if adoptedExternalGeneration, let playbackControlIntent {
        reconcilePauseControlAfterExternalMediaAdoption(
          playbackGeneration: sessionGeneration,
          command: playbackControlIntent
        )
      }
      guard sourceIsCurrent() else { return }
      guard
        refreshTracks(
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: expectedTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      _ = notifyMediaDependentObservables(
        ifPlaybackGeneration: sessionGeneration,
        nativeHandleGeneration: sourceNativeHandleGeneration,
        lifecycleControlEpoch: sourceLifecycleControlEpoch
      )

    case .encounteredError:
      guard
        publishPlaybackState(
          .error,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      if !isPlaybackRequestedActive {
        subtitleTextBridge.reset(
          awaitingNativeClear: hasLiveNativeOutputForTextSubtitleReset
        )
      }
      supersedeSeekWorkForTerminalBoundary()
      cancelPendingFrameSteps()
      clearPauseControlState(for: sessionGeneration)
      guard
        reconcilePlaybackIntent(
          for: .error,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }

    case .bufferingProgress(let pct):
      // Fill level is useful in every state, so update regardless. A
      // `.paused` player mid-preload still needs to show progress.
      guard
        performObservableMutation(
          keyPath: \.bufferFill,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storeBufferFillWithoutNestedObservation(pct)
          }
        ) else { return }
      // Only enter `.buffering` from a pre-play state. Once libVLC is
      // `.playing` or `.paused`, `.stateChanged` drives the lifecycle.
      switch state {
      case .idle, .opening, .buffering:
        if state != .buffering {
          guard
            publishPlaybackState(
              .buffering,
              ifPlaybackGeneration: sourcePlaybackGeneration,
              nativeHandleGeneration: sourceNativeHandleGeneration,
              lifecycleControlEpoch: sourceLifecycleControlEpoch
            ) else { return }
          guard
            reconcilePlaybackIntent(
              for: .buffering,
              ifPlaybackGeneration: sourcePlaybackGeneration,
              nativeHandleGeneration: sourceNativeHandleGeneration,
              lifecycleControlEpoch: sourceLifecycleControlEpoch
            ) else { return }
        }
      default:
        break
      }

    // Computed properties read fresh state from libVLC in their getter.
    // An empty `withMutation` is what re-triggers SwiftUI when the
    // underlying C state changes externally (hardware keys, system controls,
    // renderer-initiated chapter/title moves). Without this
    // the observers stay pinned to their last read.
    case .volumeChanged:
      withMutation(keyPath: \.volume) {}

    case .muted, .unmuted:
      withMutation(keyPath: \.isMuted) {}

    case .chapterChanged:
      withMutation(keyPath: \.currentChapter) {}

    case .titleSelectionChanged:
      withMutation(keyPath: \.currentTitle) {}

    case .voutChanged(let count):
      guard
        performObservableMutation(
          keyPath: \.activeVideoOutputs,
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          lifecycleControlEpoch: sourceLifecycleControlEpoch,
          mutation: {
            storeActiveVideoOutputsWithoutNestedObservation(count)
          }
        ) else { return }
      if count > 0 {
        nativePlayerHasStartedPlayback = true
      }
      guard
        refreshTracks(
          ifPlaybackGeneration: sourcePlaybackGeneration,
          nativeHandleGeneration: sourceNativeHandleGeneration,
          timelineRevision: expectedTimelineRevision,
          lifecycleControlEpoch: sourceLifecycleControlEpoch
        ) else { return }
      withMutation(keyPath: \.videoSize) {}
      guard sourceIsCurrent() else { return }
      withMutation(keyPath: \.hasVideoOutput) {}

    // Events without a matching observable property are only exposed
    // on the raw `events` stream; consumers that care subscribe there.
    case .audioDeviceChanged:
      withMutation(keyPath: \.currentAudioDevice) {}

    case .programAdded, .programDeleted, .programSelected, .programUpdated:
      withMutation(keyPath: \.programs) {}
      guard sourceIsCurrent() else { return }
      withMutation(keyPath: \.selectedProgram) {}
      guard sourceIsCurrent() else { return }
      withMutation(keyPath: \.isProgramScrambled) {}

    case .endReached:
      if !isPlaybackRequestedActive {
        subtitleTextBridge.reset()
      }
      // A consumer of the public stream can observe `.endReached` and
      // call `play()` before this internal mirror drains its copy of
      // the same event; the intent flag (set synchronously by `play()`)
      // marks that queued copy as belonging to the finished session, not
      // the new one. The bare-`load()` analog self-heals: its
      // `.mediaChanged` is queued behind the stale `.endReached` and
      // resets the flag right after.
      if !isPlaybackRequestedActive {
        guard
          performObservableMutation(
            keyPath: \.didReachEnd,
            ifPlaybackGeneration: sourcePlaybackGeneration,
            nativeHandleGeneration: sourceNativeHandleGeneration,
            lifecycleControlEpoch: sourceLifecycleControlEpoch,
            mutation: {
              storeDidReachEndWithoutNestedObservation(true)
            }
          ) else { return }
      }

    case .corked, .uncorked,
         .recordingChanged, .titleListChanged, .snapshotTaken,
         .mediaStopping:
      break
    }
  }

  /// Revalidates a sourced callback after synchronous Observation or stream
  /// publication. Direct unit-test events omit both values and intentionally
  /// retain their legacy, unscoped behavior.
  func sourcedEventIdentityIsCurrent(
    nativeHandleGeneration: UInt64?,
    playbackGeneration: UInt64?,
    allowsUnadoptedPlaybackGeneration: Bool = false
  ) -> Bool {
    if let nativeHandleGeneration {
      guard nativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
        return false
      }
    }
    guard let playbackGeneration else { return true }
    guard playbackGeneration == eventBridge.currentPlaybackGeneration else { return false }
    if allowsUnadoptedPlaybackGeneration {
      return playbackGeneration >= sessionGeneration
    }
    return playbackGeneration == sessionGeneration
  }
}
