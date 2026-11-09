import CLibVLC
import Foundation

extension Player {
  // MARK: - Observable Playback Values

  /// Fractional playback position reported by libVLC, in `0.0 ... 1.0`.
  ///
  /// Use ``seek(to:fast:)-(PlaybackPosition,_)`` for checked position-based seeking. This
  /// property is read-only so callers cannot accidentally issue an
  /// unchecked seek request through a raw `Double` write.
  public var position: Double {
    access(keyPath: \.position)
    return _position
  }

  /// Current volume level, normalized. `0.0` is silent, `1.0` is 100%.
  ///
  /// Backed by a shadow `_volume` instead of a live libVLC read.
  /// Before the audio output is initialized `libvlc_audio_get_volume`
  /// returns a negative sentinel (`-100` on libVLC 4.0), which would
  /// surface in the UI as `-100%` even while the user is hearing audio
  /// at the default level. The shadow starts at `1.0` and is refreshed
  /// from the native player on each state transition, once libVLC's
  /// audio output can be trusted.
  /// Use ``setAudioVolume(_:)`` to change volume through the typed
  /// ``Volume`` range.
  public var volume: Float {
    access(keyPath: \.volume)
    return _volume
  }

  /// Sets audio output volume through the typed ``Volume`` range.
  ///
  /// Before playback starts, libVLC may reject the native update because
  /// there is no initialized audio output yet; SwiftVLC still records the
  /// requested volume and re-applies it when playback creates or replaces
  /// the native player.
  ///
  /// - Throws: ``VLCError/operationFailed(_:)`` if playback is active and
  ///   libVLC rejects the native volume update.
  public func setAudioVolume(_ newVolume: Volume) throws(VLCError) {
    guard
      let identity = beginNativeControlMutation(
        revision: \PlayerIntentRevisions.audioVolume
      )
    else { return }
    let nativeVolume = Int32((newVolume.rawValue * 100).rounded())
    let previousVolume = _volume
    guard
      let rc = performNativeControlMutation(
        keyPath: \.volume,
        identity: identity,
        revision: \PlayerIntentRevisions.audioVolume,
        mutation: { pointer in
          _volume = newVolume.rawValue
          #if DEBUG
          recordObservableControlNativeDispatch(
            .audioVolume(newVolume.rawValue),
            pointer: pointer
          )
          #endif
          return libvlc_audio_set_volume(pointer, nativeVolume)
        }
      )
    else { return }
    if rc != 0, currentMedia != nil, state.isActive {
      _ = performNativeControlMutation(
        keyPath: \.volume,
        identity: identity,
        revision: \PlayerIntentRevisions.audioVolume
      ) { _ in
        _volume = previousVolume
      }
      throw .operationFailed("Set audio volume to \(newVolume.rawValue)")
    }
  }

  /// Whether audio is muted. Shadowed by `_isMuted` for the same
  /// reason as `volume`: `libvlc_audio_get_mute` returns `-1` when the
  /// mute status is undefined, which a naive `Int32 > 0` check would
  /// silently map to `false` and hide a real mute toggle.
  public var isMuted: Bool {
    get {
      access(keyPath: \.isMuted)
      return _isMuted
    }
    set {
      guard
        let identity = beginNativeControlMutation(
          revision: \PlayerIntentRevisions.mute
        )
      else { return }
      _ = performNativeControlMutation(
        keyPath: \.isMuted,
        identity: identity,
        revision: \PlayerIntentRevisions.mute
      ) { pointer in
        _isMuted = newValue
        #if DEBUG
        recordObservableControlNativeDispatch(.mute(newValue), pointer: pointer)
        #endif
        libvlc_audio_set_mute(pointer, newValue ? 1 : 0)
      }
    }
  }

  /// Playback-rate setting currently reported by libVLC. `1.0` is normal speed.
  ///
  /// This value reflects libVLC's control state, not measured media throughput.
  /// A rate request is applied asynchronously and unsupported inputs may fall
  /// back to another value after ``setPlaybackRate(_:)`` returns. On a linked
  /// version-7 native extension, ``effectivePlaybackRateResolutions``
  /// invalidates this observable when VLC reports an effective-rate resolution.
  public var rate: Float {
    access(keyPath: \.rate)
    return libvlc_media_player_get_rate(pointer)
  }

  /// Submits a playback-rate request to libVLC.
  ///
  /// libVLC's return value reports only an immediate API error. A zero result
  /// does not prove that the active input applied the requested rate: protocol,
  /// demuxer, or decoder constraints can asynchronously substitute another
  /// rate. Read ``rate`` after the input processes the request when that
  /// distinction matters.
  ///
  /// This synchronous API cannot correlate a request with a later resolution.
  /// Observe ``effectivePlaybackRateResolutions`` for effective resolutions.
  /// A queued active-input request produces no value if its resolved rate is
  /// unchanged. With no input, or if queuing fails, VLC may instead report the
  /// current effective state again. Check
  /// ``supportsEffectivePlaybackRateEvents`` before depending on that stream.
  ///
  /// ``setPlaybackRate(_:)`` is the public mutator.
  ///
  /// - Parameter newRate: Target rate. `1.0` is normal speed.
  /// - Throws: ``VLCError/operationFailed(_:)`` only if the native API reports
  ///   an immediate request error.
  func setRate(_ newRate: PlaybackRate) throws(VLCError) {
    guard
      let identity = beginNativeControlMutation(
        revision: \PlayerIntentRevisions.playbackRate
      )
    else { return }
    guard
      let rc = performNativeControlMutation(
        keyPath: \.rate,
        identity: identity,
        revision: \PlayerIntentRevisions.playbackRate,
        mutation: { pointer in
          #if DEBUG
          recordObservableControlNativeDispatch(
            .playbackRate(newRate.rawValue),
            pointer: pointer
          )
          #endif
          return libvlc_media_player_set_rate(pointer, newRate.rawValue)
        }
      )
    else { return }
    if rc != 0 {
      throw .operationFailed("Set rate to \(newRate.rawValue)")
    }
  }

  /// Whether the linked pinned libVLC emits effective rate resolutions.
  ///
  /// Older released archives remain source- and binary-compatible but cannot
  /// invalidate ``rate`` asynchronously because their event bridge lacks the
  /// native callback.
  public nonisolated static var supportsEffectivePlaybackRateEvents: Bool {
    swiftvlc_media_player_rate_changed_event_available()
  }

  /// The currently selected audio track, or `nil` if none is selected.
  ///
  /// Setting a track selects it for the rest of the playback session, and
  /// setting `nil` deselects audio until another track is chosen; audio
  /// tracks the stream adds later do not override either choice. Writes
  /// apply in order, and the getter catches up once libVLC reports the
  /// change. A track of another ``TrackType`` is ignored. A stop, replay,
  /// or new media starts again from the stream's default selection.
  public var selectedAudioTrack: Track? {
    get {
      access(keyPath: \.selectedAudioTrack)
      guard nativeHandleRepresentsCurrentMedia else { return nil }
      return audioTracks.first(where: \.isSelected)
    }
    set {
      guard newValue.map({ $0.type == .audio }) ?? true else { return }
      guard
        let identity = beginNativeControlMutation(
          revision: \PlayerIntentRevisions.audioTrackSelection,
          requiresCurrentMediaHandle: true
        )
      else { return }
      _ = performNativeControlMutation(
        keyPath: \.selectedAudioTrack,
        identity: identity,
        revision: \PlayerIntentRevisions.audioTrackSelection
      ) { pointer in
        selectTrack(newValue, type: .audio, on: pointer)
      }
    }
  }

  /// The currently selected subtitle track, or `nil` if subtitles are off.
  ///
  /// Setting a track selects it for the rest of the playback session, and
  /// setting `nil` turns subtitles off until another track is chosen;
  /// subtitle tracks the stream adds later do not override either choice.
  /// Writes apply in order, and the getter catches up once libVLC reports
  /// the change. A track of another ``TrackType`` is ignored. A stop,
  /// replay, or new media starts again from the stream's default selection.
  public var selectedSubtitleTrack: Track? {
    get {
      access(keyPath: \.selectedSubtitleTrack)
      guard nativeHandleRepresentsCurrentMedia else { return nil }
      return subtitleTracks.first(where: \.isSelected)
    }
    set {
      guard newValue.map({ $0.type == .subtitle }) ?? true else { return }
      guard
        let identity = beginNativeControlMutation(
          revision: \PlayerIntentRevisions.subtitleTrackSelection,
          requiresCurrentMediaHandle: true
        )
      else { return }
      _ = performNativeControlMutation(
        keyPath: \.selectedSubtitleTrack,
        identity: identity,
        revision: \PlayerIntentRevisions.subtitleTrackSelection
      ) { pointer in
        selectTrack(newValue, type: .subtitle, on: pointer)
      }
    }
  }

  /// Video aspect ratio override.
  public var aspectRatio: AspectRatio {
    get {
      access(keyPath: \.aspectRatio)
      return _aspectRatio
    }
    set {
      guard
        let identity = beginNativeControlMutation(
          revision: \PlayerIntentRevisions.aspectRatio
        )
      else { return }
      _ = performNativeControlMutation(
        keyPath: \.aspectRatio,
        identity: identity,
        revision: \PlayerIntentRevisions.aspectRatio
      ) { pointer in
        _aspectRatio = newValue
        #if DEBUG
        recordObservableControlNativeDispatch(.aspectRatio(newValue), pointer: pointer)
        #endif
        applyAspectRatio(newValue, to: pointer)
      }
    }
  }

  /// Audio delay relative to video. Positive values delay audio (make it play later).
  ///
  /// This is the delay last set with ``setAudioDelay(_:)``, which checks
  /// the duration conversion. It is a player setting, so it holds while
  /// nothing is playing.
  public var audioDelay: Duration {
    access(keyPath: \.audioDelay)
    return .microseconds(_audioDelayMicroseconds)
  }

  /// Sets the audio delay relative to video.
  ///
  /// The delay applies to the current playback and to every later one —
  /// after ``stop()``, on replay, and for the next media — until you set it
  /// again. Set while stopped, it takes effect when playback starts.
  ///
  /// - Throws: ``VLCError/invalidInput(_:)`` if the duration cannot be
  ///   represented in libVLC's microsecond unit.
  public func setAudioDelay(_ newDelay: Duration) throws(VLCError) {
    let microseconds = try newDelay.checkedMicroseconds(parameter: "audioDelay")
    guard
      let identity = beginNativeControlMutation(
        revision: \PlayerIntentRevisions.audioDelay
      )
    else { return }
    performNativeControlMutation(
      keyPath: \.audioDelay,
      identity: identity,
      revision: \PlayerIntentRevisions.audioDelay
    ) { pointer in
      _audioDelayMicroseconds = microseconds
      #if DEBUG
      recordObservableControlNativeDispatch(.audioDelay(newDelay), pointer: pointer)
      #endif
      // Dropped when no input exists; `applyRequestedDelays(to:)` carries
      // the shadow into the next one.
      _ = libvlc_audio_set_delay(pointer, microseconds)
    }
  }

  /// Subtitle delay relative to video. Positive values delay subtitles (make them appear later).
  ///
  /// This is the delay last set with ``setSubtitleDelay(_:)``, which checks
  /// the duration conversion. It is a player setting, so it holds while
  /// nothing is playing.
  public var subtitleDelay: Duration {
    access(keyPath: \.subtitleDelay)
    return .microseconds(_subtitleDelayMicroseconds)
  }

  /// Sets the subtitle delay relative to video.
  ///
  /// The delay applies to the current playback and to every later one —
  /// after ``stop()``, on replay, and for the next media — until you set it
  /// again. Set while stopped, it takes effect when playback starts.
  ///
  /// - Throws: ``VLCError/invalidInput(_:)`` if the duration cannot be
  ///   represented in libVLC's microsecond unit.
  public func setSubtitleDelay(_ newDelay: Duration) throws(VLCError) {
    let microseconds = try newDelay.checkedMicroseconds(parameter: "subtitleDelay")
    guard
      let identity = beginNativeControlMutation(
        revision: \PlayerIntentRevisions.subtitleDelay
      )
    else { return }
    performNativeControlMutation(
      keyPath: \.subtitleDelay,
      identity: identity,
      revision: \PlayerIntentRevisions.subtitleDelay
    ) { pointer in
      _subtitleDelayMicroseconds = microseconds
      #if DEBUG
      recordObservableControlNativeDispatch(.subtitleDelay(newDelay), pointer: pointer)
      #endif
      _ = libvlc_video_set_spu_delay(pointer, microseconds)
    }
  }

  /// Applies the requested audio and subtitle delays to the input on
  /// `pointer`.
  ///
  /// libVLC keeps both delays on the current input only: it drops a
  /// request made while no input exists, and every new input — a replay,
  /// the next media, a replacement handle — starts from zero. Called
  /// wherever a new input can appear; a no-op once the input carries them.
  func applyRequestedDelays(to pointer: OpaquePointer) {
    if libvlc_audio_get_delay(pointer) != _audioDelayMicroseconds {
      _ = libvlc_audio_set_delay(pointer, _audioDelayMicroseconds)
    }
    if libvlc_video_get_spu_delay(pointer) != _subtitleDelayMicroseconds {
      _ = libvlc_video_set_spu_delay(pointer, _subtitleDelayMicroseconds)
    }
  }

  /// Subtitle text scale factor (1.0 = 100%, 0.5 = 50%, 2.0 = 200%).
  ///
  /// Use ``setSubtitleScale(_:)`` to mutate this value through the typed
  /// ``SubtitleScale`` range.
  public var subtitleTextScale: Float {
    access(keyPath: \.subtitleTextScale)
    return libvlc_video_get_spu_text_scale(pointer)
  }

  /// Sets subtitle text scale through the typed ``SubtitleScale`` range.
  public func setSubtitleScale(_ newScale: SubtitleScale) {
    guard
      let identity = beginNativeControlMutation(
        revision: \PlayerIntentRevisions.subtitleScale
      )
    else { return }
    _ = performNativeControlMutation(
      keyPath: \.subtitleTextScale,
      identity: identity,
      revision: \PlayerIntentRevisions.subtitleScale
    ) { pointer in
      #if DEBUG
      recordObservableControlNativeDispatch(
        .subtitleScale(newScale.rawValue),
        pointer: pointer
      )
      #endif
      libvlc_video_set_spu_text_scale(pointer, newScale.rawValue)
    }
  }

  /// The player's role, used to hint the system about audio behavior.
  public var role: PlayerRole {
    get {
      access(keyPath: \.role)
      return PlayerRole(from: libvlc_media_player_get_role(pointer))
    }
    set {
      guard
        let identity = beginNativeControlMutation(
          revision: \PlayerIntentRevisions.role
        )
      else { return }
      _ = performNativeControlMutation(
        keyPath: \.role,
        identity: identity,
        revision: \PlayerIntentRevisions.role
      ) { pointer in
        #if DEBUG
        recordObservableControlNativeDispatch(.role(newValue), pointer: pointer)
        #endif
        return libvlc_media_player_set_role(pointer, newValue.cValue)
      }
    }
  }

  // MARK: - Convenience

  /// Whether transport controls should currently present playback as
  /// playing.
  ///
  /// This follows the latest accepted play/resume/pause intent rather
  /// than waiting for libVLC's asynchronous ``state`` transitions. Use
  /// ``state`` when you need the strict native lifecycle state.
  public var isPlaying: Bool {
    access(keyPath: \.isPlaying)
    return isPlaybackRequestedActive
  }

  /// Whether playback is active (playing or buffering during playback).
  public var isActive: Bool {
    access(keyPath: \.isActive)
    return state.isActive
  }

  /// Convenience access to current media statistics.
  public var statistics: MediaStatistics? {
    currentMedia?.statistics()
  }
}
