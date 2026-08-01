import CLibVLC
import os
import Synchronization

/// Event consumer that mirrors `PlayerEvent`s onto `Player`'s
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
  /// underlying handle, not the cached `state` property.
  var nativePlaybackState: PlayerState {
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
    if libvlc_media_player_get_time(pointer) > 0 {
      return true
    }
    return libvlc_audio_get_volume(pointer) < 0
  }

  // MARK: - Event consumer task

  /// Spawns the event-consuming `Task` that mirrors libVLC events
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
    let stream = bridge.makeSourcedStream(policy: .unbounded)
    eventTask = Task { [weak self] in
      for await sourcedEvent in stream {
        guard !Task.isCancelled else { return }
        self?.handleSourcedEvent(sourcedEvent)
        // Yield after each event so other main-actor work (UI updates,
        // tests, etc.) isn't starved when VLC produces events rapidly.
        await Task.yield()
      }
    }
  }

  // MARK: - handleEvent dispatch

  func handleSourcedEvent(_ sourcedEvent: SourcedPlayerEvent) {
    guard
      sourcedEvent.nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
    else { return }
    if case .mediaChanged = sourcedEvent.event {
      guard sourcedEvent.playbackGeneration >= sessionGeneration else { return }
      handleEvent(
        sourcedEvent.event,
        sourcePlaybackGeneration: sourcedEvent.playbackGeneration
      )
      return
    }
    guard sourcedEvent.playbackGeneration == sessionGeneration else { return }
    guard isTimelineSampleCurrent(sourcedEvent) else { return }
    handleEvent(sourcedEvent.event)
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
      sourcedEvent.timelineRevision >= acceptedTimelineRevision
    default:
      true
    }
  }

  /// Maps a single `PlayerEvent` to the observable-property updates and
  /// state-machine transitions it implies. Called from
  /// `startEventConsumer`'s loop on every event the bridge yields.
  func handleEvent(
    _ event: PlayerEvent,
    sourcePlaybackGeneration: UInt64? = nil
  ) {
    let interval = Signposts.signposter.beginInterval("Player.handleEvent")
    defer { Signposts.signposter.endInterval("Player.handleEvent", interval) }
    switch event {
    case .stateChanged(let newState):
      publishPlaybackState(newState)
      updatePauseTransition(for: newState)
      reconcilePlaybackIntent(for: newState)
      if case .stopped = newState {
        currentTime = .zero
        bufferFill = 0
        withMutation(keyPath: \.position) {
          _position = 0
        }
        withMutation(keyPath: \.abLoopState) {}
      }
      // libVLC doesn't always emit `MediaPlayerLengthChanged`,
      // `MediaPlayerSeekableChanged`, or `MediaPlayerPausableChanged`
      // events on the player side. For some inputs the demuxer publishes
      // those via `MediaParsedChanged` on `Media` (which we don't bridge
      // to the player), or sets the fields before the player has a
      // chance to attach its event listener. Polling on every state
      // transition catches those cases. It's three C calls and is
      // idempotent when the events do fire.
      refreshNativeStateIfNeeded()
      performDeferredPauseCommandIfNeeded()

    case .timeChanged(let time):
      currentTime = time
      if duration == nil || !isSeekable || !isPausable {
        refreshNativeStateIfNeeded()
      }
      performDeferredPauseCommandIfNeeded()

    case .positionChanged(let pos):
      withMutation(keyPath: \.position) {
        _position = pos
      }

    case .lengthChanged(let length):
      duration = length

    case .seekableChanged(let seekable):
      isSeekable = seekable

    case .pausableChanged(let pausable):
      isPausable = pausable
      performDeferredPauseCommandIfNeeded()

    case .tracksChanged:
      refreshTracks()
      // Adaptive streams can switch resolution mid-stream without any
      // dedicated size event; libVLC reports the change through the
      // track list (ES selection/update), so re-signal the decoded
      // size here for observers to re-read. `hasVideoOutput` is a
      // selected-track probe over the same data, so it is track-driven
      // too.
      withMutation(keyPath: \.videoSize) {}
      withMutation(keyPath: \.hasVideoOutput) {}

    case .mediaChanged:
      let previousSessionGeneration = sessionGeneration
      let playbackControlIntent = playbackControlIntent
      syncCurrentMediaFromNative()
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
      } else if currentMedia?.pointer != sessionGenerationMedia {
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
      let adoptedExternalGeneration = sessionGeneration > previousSessionGeneration
      let carriesPlaybackControl = adoptedExternalGeneration && playbackControlIntent != nil
      resetMediaDerivedState(preservingPlaybackIntent: carriesPlaybackControl)
      if adoptedExternalGeneration, let playbackControlIntent {
        reconcilePauseControlAfterExternalMediaAdoption(
          playbackGeneration: sessionGeneration,
          command: playbackControlIntent
        )
      }
      refreshTracks()
      notifyMediaDependentObservables()

    case .encounteredError:
      publishPlaybackState(.error)
      clearPauseControlState(for: sessionGeneration)
      reconcilePlaybackIntent(for: .error)

    case .bufferingProgress(let pct):
      // Fill level is useful in every state, so update regardless. A
      // `.paused` player mid-preload still needs to show progress.
      bufferFill = pct
      // Only enter `.buffering` from a pre-play state. Once libVLC is
      // `.playing` or `.paused`, `.stateChanged` drives the lifecycle.
      switch state {
      case .idle, .opening, .buffering:
        if state != .buffering {
          publishPlaybackState(.buffering)
          reconcilePlaybackIntent(for: .buffering)
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
      activeVideoOutputs = count
      withMutation(keyPath: \.videoSize) {}
      withMutation(keyPath: \.hasVideoOutput) {}

    // Events without a matching observable property are only exposed
    // on the raw `events` stream; consumers that care subscribe there.
    case .audioDeviceChanged:
      withMutation(keyPath: \.currentAudioDevice) {}

    case .programAdded, .programDeleted, .programSelected, .programUpdated:
      withMutation(keyPath: \.programs) {}
      withMutation(keyPath: \.selectedProgram) {}
      withMutation(keyPath: \.isProgramScrambled) {}

    case .endReached:
      // A consumer of the public stream can observe `.endReached` and
      // call `play()` before this internal mirror drains its copy of
      // the same event; the intent flag (set synchronously by `play()`)
      // marks that queued copy as belonging to the finished session, not
      // the new one. The bare-`load()` analog self-heals: its
      // `.mediaChanged` is queued behind the stale `.endReached` and
      // resets the flag right after.
      if !isPlaybackRequestedActive {
        didReachEnd = true
      }

    case .corked, .uncorked,
         .recordingChanged, .titleListChanged, .snapshotTaken,
         .mediaStopping:
      break
    }
  }

  // MARK: - Playback state + intent publication

  func publishPlaybackState(_ newState: PlayerState) {
    state = newState
    withMutation(keyPath: \.isActive) {}
    // The single funnel for `state`, and therefore the only place that can
    // see *every* lifecycle transition. Broadcasting from here rather than
    // from the raw `.stateChanged` event is what puts `.error` and
    // `.buffering` on the stream at all: libVLC reports those as
    // `.encounteredError` and `.bufferingProgress`, so neither has ever
    // produced a `.stateChanged` to forward.
    stateTransitionBridge.broadcast(newState)
    publishPlaybackStatus()
  }

  /// Republishes the current state paired with the session it belongs to.
  ///
  /// Called from both funnels rather than one: a state change keeps the same
  /// generation, and a media change keeps the same state, so either alone
  /// leaves ``Player/playbackStatus`` describing a pair that was never true.
  func publishPlaybackStatus() {
    playbackStatusBridge.broadcast(
      PlaybackStatus(state: state, generation: PlaybackGeneration(sessionGeneration))
    )
  }

  func publishPlaybackIntent(_ active: Bool) {
    guard isPlaybackRequestedActive != active else { return }
    isPlaybackRequestedActive = active
    // Mirrored synchronously so off-main callers — AVKit and AppKit PiP
    // callbacks, which must answer immediately — can read the current intent
    // without hopping to the main actor.
    nonisolatedPlaybackIntent.store(active, ordering: .releasing)
    withMutation(keyPath: \.isPlaying) {}
    playbackIntentBridge.broadcast(active)
  }

  func setPlaybackIntentFromExternalControl(_ active: Bool) {
    publishPlaybackIntent(active)
  }

  func setPlaybackControlIntent(_ command: DeferredPauseCommand) {
    playbackControlIntent = command
    publishPlaybackIntent(command == .resume)
  }

  /// Reconciles the published playback intent with libVLC's reported
  /// state, *unless* a user-initiated transition is in flight. While
  /// pausing or resuming, the intent published by `pause()`/`resume()`
  /// wins until the matching state arrives.
  func reconcilePlaybackIntent(for state: PlayerState) {
    switch state {
    case .opening, .buffering, .playing:
      guard pauseTransition != .pausing, deferredPauseCommand != .pause else { return }
      publishPlaybackIntent(true)

    case .paused:
      guard pauseTransition != .resuming, deferredPauseCommand != .resume else { return }
      publishPlaybackIntent(false)

    case .idle, .stopped, .stopping, .error:
      guard !hasPauseControl(after: sessionGeneration) else { return }
      publishPlaybackIntent(false)
    }
  }

  // MARK: - Pause transition + deferred command

  /// Closes out a pause/resume transition once libVLC reports the
  /// matching state, or clears any pending state on terminal states.
  func updatePauseTransition(for newState: PlayerState) {
    switch (pauseTransition, newState) {
    case (.pausing, .paused), (.resuming, .playing):
      guard pauseTransitionPlaybackGeneration == sessionGeneration else { return }
      pauseTransition = nil
      performDeferredPauseCommandIfNeeded()
    case (_, .idle), (_, .stopped), (_, .stopping), (_, .error):
      clearPauseControlState(for: sessionGeneration)
    default:
      break
    }
  }

  /// Clears only pause work owned by `playbackGeneration`. A queued event for
  /// an outgoing playlist item must not erase work already accepted for its
  /// successor on the callback lane.
  func clearPauseControlState(for playbackGeneration: UInt64) {
    if pauseTransitionPlaybackGeneration == playbackGeneration {
      pauseTransition = nil
    }
    if deferredPauseCommandPlaybackGeneration == playbackGeneration {
      deferredPauseCommand = nil
    }
  }

  /// Whether the callback lane has already accepted pause/resume work for a
  /// media generation that the main actor has not adopted yet.
  func hasPauseControl(after playbackGeneration: UInt64) -> Bool {
    (pauseTransitionPlaybackGeneration ?? 0) > playbackGeneration
      || (deferredPauseCommandPlaybackGeneration ?? 0) > playbackGeneration
  }

  /// If a pause/resume command was deferred (because the player wasn't
  /// in a stable state at the time), retry it now.
  func performDeferredPauseCommandIfNeeded() {
    guard
      pauseTransition == nil,
      let command = deferredPauseCommand,
      let playbackGeneration = deferredPauseCommandPlaybackGeneration,
      playbackGeneration == sessionGeneration
    else {
      return
    }
    guard playbackGeneration == eventBridge.currentPlaybackGeneration else {
      // The callback lane has already adopted a successor. Retrying this
      // outgoing command would act on the shared native handle's new media.
      deferredPauseCommand = nil
      return
    }
    deferredPauseCommand = nil
    switch command {
    case .pause:
      _ = issuePause(playbackGeneration: playbackGeneration)
    case .resume:
      _ = issueResume(playbackGeneration: playbackGeneration)
    }
  }

  // MARK: - Media-derived state reset

  /// Resets the observable state that depends on the current media —
  /// times, duration, seek/pause flags, buffer fill. Called when media
  /// is loaded or replaced.
  func resetMediaDerivedState(preservingPlaybackIntent: Bool = false) {
    // New media, new timeline: clock samples still queued from the previous
    // one describe a media that is no longer loaded and must not be applied.
    acceptedTimelineRevision = eventBridge.advanceTimelineRevision()
    // `duration` and `isSeekable` publish the capability snapshot from their
    // own `didSet`, so clearing them one at a time would briefly expose
    // "duration cleared, seekability still the previous media's". Suppress
    // those partial publishes and emit one atomic snapshot below.
    isSuppressingCapabilityPublish = true
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
    publishPlaybackIntent(intendsActivePlayback)
    currentTime = .zero
    duration = nil
    isSeekable = false
    isPausable = false
    bufferFill = 0
    activeVideoOutputs = 0
    didReachEnd = false
    withMutation(keyPath: \.position) {
      _position = 0
    }
    isSuppressingCapabilityPublish = false
    // New media, new capability generation. The bump and the reset values are
    // written under one lock acquisition, so a reader can never see the new
    // generation carrying the outgoing media's capability — which would make
    // it distrust the poll for the rest of that media's lifetime.
    advanceCapabilityGeneration()
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

  /// Signals every observable whose value is read live from libVLC and
  /// can change when a new media is loaded. libVLC emits no standalone
  /// events for most of these (no `RateChanged`, no `AudioDelayChanged`,
  /// etc. on the player's event manager), so SwiftUI would otherwise
  /// keep showing the pre-swap value. Empty `withMutation` calls force
  /// the getters to re-run next frame.
  func notifyMediaDependentObservables() {
    withMutation(keyPath: \.rate) {}
    withMutation(keyPath: \.audioDelay) {}
    withMutation(keyPath: \.subtitleDelay) {}
    withMutation(keyPath: \.subtitleTextScale) {}
    withMutation(keyPath: \.role) {}
    withMutation(keyPath: \.stereoMode) {}
    withMutation(keyPath: \.mixMode) {}
    withMutation(keyPath: \.teletextPage) {}
    withMutation(keyPath: \.currentChapter) {}
    withMutation(keyPath: \.currentTitle) {}
    withMutation(keyPath: \.abLoopState) {}
    withMutation(keyPath: \.programs) {}
    withMutation(keyPath: \.selectedProgram) {}
    withMutation(keyPath: \.isProgramScrambled) {}
    withMutation(keyPath: \.currentAudioDevice) {}
    withMutation(keyPath: \.selectedAudioTrack) {}
    withMutation(keyPath: \.selectedSubtitleTrack) {}
    withMutation(keyPath: \.videoSize) {}
    withMutation(keyPath: \.hasVideoOutput) {}
  }

  /// Reads length / seekable / pausable directly from libVLC and
  /// publishes any changes to the matching observable property. Called
  /// on state transitions and early time updates as a resilient companion
  /// to `MediaPlayerLengthChanged` / `SeekableChanged` /
  /// `PausableChanged`, which are not guaranteed to fire on the player's
  /// event manager for every media.
  func refreshNativeStateIfNeeded() {
    if duration == nil {
      let ms = libvlc_media_player_get_length(pointer)
      if ms > 0 {
        duration = .milliseconds(ms)
      }
    }

    let nativeSeekable = libvlc_media_player_is_seekable(pointer)
    if isSeekable != nativeSeekable {
      isSeekable = nativeSeekable
    }

    let nativePausable = libvlc_media_player_can_pause(pointer)
    if isPausable != nativePausable {
      isPausable = nativePausable
    }

    // libVLC reports volume/mute via `libvlc_audio_get_volume` and
    // `libvlc_audio_get_mute`; both return negative sentinels (observed
    // as `-100` and `-1` respectively on libVLC 4.0) when the audio
    // output isn't initialized yet. Only sync the shadow state from
    // valid (non-negative) reads.
    let nativeVolume = libvlc_audio_get_volume(pointer)
    if nativeVolume >= 0 {
      let normalized = Float(nativeVolume) / 100.0
      if abs(_volume - normalized) > 0.001 {
        withMutation(keyPath: \.volume) {
          _volume = normalized
        }
      }
    }

    let nativeMute = libvlc_audio_get_mute(pointer)
    if nativeMute >= 0 {
      let muted = nativeMute > 0
      if _isMuted != muted {
        withMutation(keyPath: \.isMuted) {
          _isMuted = muted
        }
      }
    }
  }

  /// Re-reads the current media from libVLC, wrapping the C pointer in
  /// a fresh `Media` value if one is now attached. Called when libVLC
  /// emits `MediaChanged` (for media swaps initiated from a list
  /// player, etc.).
  func syncCurrentMediaFromNative() {
    guard let media = libvlc_media_player_get_media(pointer) else {
      currentMedia = nil
      return
    }
    currentMedia = Media(retaining: media)
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
    isPlaybackRequestedActive: Bool? = nil,
    currentTime: Duration? = nil,
    duration: Duration? = nil,
    position: Double? = nil,
    isSeekable: Bool? = nil,
    isPausable: Bool? = nil
  ) {
    if let state {
      self.state = state
      publishPlaybackIntent(state.isActive)
    }
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
