import CLibVLC
import os

/// Event consumer that mirrors `PlayerEvent`s onto `Player`'s
/// `@Observable` properties, plus the deferred-pause / playback-intent
/// reconciliation state machine.
extension Player {
  // MARK: - Native state probes

  /// libVLC's view of the player state — read directly from the
  /// underlying handle, not the cached `state` property.
  var nativePlaybackState: PlayerState {
    PlayerState(from: libvlc_media_player_get_state(pointer))
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
  func startEventConsumer() {
    let bridge = eventBridge
    let stream = bridge.makeStream()
    eventTask = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled else { return }
        self?.handleEvent(event)
        // Yield after each event so other main-actor work (UI updates,
        // tests, etc.) isn't starved when VLC produces events rapidly.
        await Task.yield()
      }
    }
  }

  // MARK: - handleEvent dispatch

  /// Maps a single `PlayerEvent` to the observable-property updates and
  /// state-machine transitions it implies. Called from
  /// `startEventConsumer`'s loop on every event the bridge yields.
  func handleEvent(_ event: PlayerEvent) {
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

    case .mediaChanged:
      syncCurrentMediaFromNative()
      resetMediaDerivedState()
      refreshTracks()
      notifyMediaDependentObservables()

    case .encounteredError:
      publishPlaybackState(.error)
      pauseTransition = nil
      deferredPauseCommand = nil
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
    // underlying C state changes externally (hardware keys, AirPlay,
    // CarPlay, renderer-initiated chapter/title moves). Without this
    // the observers stay pinned to their last read.
    case .volumeChanged:
      withMutation(keyPath: \.volume) {}

    case .muted, .unmuted:
      withMutation(keyPath: \.isMuted) {}

    case .chapterChanged:
      withMutation(keyPath: \.currentChapter) {}

    case .titleSelectionChanged:
      withMutation(keyPath: \.currentTitle) {}

    // Events without a matching observable property are only exposed
    // on the raw `events` stream; consumers that care subscribe there.
    case .audioDeviceChanged:
      withMutation(keyPath: \.currentAudioDevice) {}

    case .programAdded, .programDeleted, .programSelected, .programUpdated:
      withMutation(keyPath: \.programs) {}
      withMutation(keyPath: \.selectedProgram) {}
      withMutation(keyPath: \.isProgramScrambled) {}

    case .corked, .uncorked, .voutChanged,
         .recordingChanged, .titleListChanged, .snapshotTaken,
         .mediaStopping:
      break
    }
  }

  // MARK: - Playback state + intent publication

  func publishPlaybackState(_ newState: PlayerState) {
    state = newState
    withMutation(keyPath: \.isActive) {}
  }

  func publishPlaybackIntent(_ active: Bool) {
    guard isPlaybackRequestedActive != active else { return }
    isPlaybackRequestedActive = active
    withMutation(keyPath: \.isPlaying) {}
    playbackIntentBridge.broadcast(active)
  }

  func setPlaybackIntentFromExternalControl(_ active: Bool) {
    publishPlaybackIntent(active)
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
      publishPlaybackIntent(false)
    }
  }

  // MARK: - Pause transition + deferred command

  /// Closes out a pause/resume transition once libVLC reports the
  /// matching state, or clears any pending state on terminal states.
  func updatePauseTransition(for newState: PlayerState) {
    switch (pauseTransition, newState) {
    case (.pausing, .paused), (.resuming, .playing):
      pauseTransition = nil
      performDeferredPauseCommandIfNeeded()
    case (_, .idle), (_, .stopped), (_, .stopping), (_, .error):
      pauseTransition = nil
      deferredPauseCommand = nil
    default:
      break
    }
  }

  /// If a pause/resume command was deferred (because the player wasn't
  /// in a stable state at the time), retry it now.
  func performDeferredPauseCommandIfNeeded() {
    guard pauseTransition == nil, let command = deferredPauseCommand else {
      return
    }
    deferredPauseCommand = nil
    switch command {
    case .pause:
      pause()
    case .resume:
      resume()
    }
  }

  // MARK: - Media-derived state reset

  /// Resets the observable state that depends on the current media —
  /// times, duration, seek/pause flags, buffer fill. Called when media
  /// is loaded or replaced.
  func resetMediaDerivedState() {
    pauseTransition = nil
    deferredPauseCommand = nil
    publishPlaybackIntent(false)
    currentTime = .zero
    duration = nil
    isSeekable = false
    isPausable = false
    bufferFill = 0
    withMutation(keyPath: \.position) {
      _position = 0
    }
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
}
