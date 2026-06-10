import CLibVLC
import Foundation
import os

/// Awaitable stop and full-teardown choreography, plus the per-player
/// state carried across native-handle replacements.
extension Player {
  /// Stops playback and suspends until the native stop completes and the
  /// audio/video outputs are released.
  ///
  /// libVLC's stop is asynchronous; the header is explicit that callers
  /// must wait for the `Stopped` event to know it finished. Use this
  /// before work that races the output drain — most commonly
  /// `AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)`,
  /// which fails session-busy while the audio output is still alive.
  ///
  /// Awaits the **explicit-stop** path only: on the media-replacement
  /// path the outgoing handle's `Stopped` is unobservable (see
  /// ``events(policy:filter:)``), and ``recast(to:)`` awaits
  /// new-session readiness instead. Returns immediately when the player
  /// is already terminal. A defensive 10-second ceiling keeps a wedged
  /// pipeline from hanging the caller.
  public func stopAndWait() async {
    switch nativePlaybackState {
    case .idle, .stopped, .error:
      stop()
      return
    default:
      break
    }
    let source = Self.sourceIdentifier(for: pointer)
    let stream = eventBridge.makeSourcedStream(policy: .unbounded)
    // A terminal event that fired between the check above and the
    // subscription is invisible to the stream — re-check before waiting
    // so an in-flight stop completing right here costs nothing instead
    // of the full defensive timeout.
    switch nativePlaybackState {
    case .idle, .stopped, .error:
      stop()
      return
    default:
      break
    }
    stop()
    await Self.awaitTerminalStop(on: stream, source: source)
    // The internal consumer mirrors the same terminal event onto
    // `state` on its own main-actor schedule and may still be draining
    // its backlog when the dedicated wait resumes. Reconcile here so
    // the documented post-condition — the player is terminal on
    // return — holds for the observable mirror, not just the native
    // handle. Idempotent with the consumer's later delivery.
    let terminal = nativePlaybackState
    if terminal == .stopped || terminal == .error, state != terminal {
      handleEvent(.stateChanged(terminal))
    }
  }

  private static func awaitTerminalStop(
    on stream: AsyncStream<SourcedPlayerEvent>,
    source: UInt
  )
    async {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await sourced in stream {
          if
            sourced.source == source,
            case .stateChanged(let state) = sourced.event,
            state == .stopped || state == .error {
            return true
          }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(10))
        return false
      }
      if let first = await group.next(), !first {
        #if DEBUG
        Signposts.signposter.emitEvent("Player.stopAndWait.timeout")
        #endif
      }
      group.cancelAll()
    }
  }

  /// Awaitable full teardown — the `deinit` choreography, on demand.
  ///
  /// Cancels the event consumer, finishes the intent stream, detaches
  /// the drawable, then performs the offloaded native teardown
  /// (event-bridge invalidation → stop → release) and suspends until it
  /// completes — after return, no libVLC thread owned by this player is
  /// draining. The player is **unusable afterwards**: its event streams
  /// are finished and its native handle is replaced by an inert one so
  /// stray calls are harmless no-ops. Idempotent.
  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    // A still-attached list player would keep driving the handle being
    // torn down (its native binding retains it past the release) —
    // detach through the public setter so suppression and the native
    // binding are both released.
    if let listPlayer = attachedMediaListPlayer {
      listPlayer.mediaPlayer = nil
    }
    publishPlaybackIntent(false)
    pauseTransition = nil
    deferredPauseCommand = nil
    eventTask?.cancel()
    eventTask = nil
    _marqueeRestoreTask?.cancel()
    playbackIntentBridge.finishAll()
    libvlc_media_player_set_nsobject(pointer, nil)

    let bridge = eventBridge
    nonisolated(unsafe) let drawables =
      drawable.map { retainedDrawablesUntilNativePlayerRelease + [$0] }
        ?? retainedDrawablesUntilNativePlayerRelease
    nonisolated(unsafe) let p = pointer
    let resumeBeforeRelease = pauseTransition == .pausing || nativePlaybackState == .paused
    drawable = nil
    retainedDrawablesUntilNativePlayerRelease.removeAll()
    pointer = Self.makeNativePlayer(instance: instance)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .utility).async {
        Self.teardownNativePlayer(
          p,
          bridge: bridge,
          retainedDrawables: drawables,
          resumeBeforeStop: resumeBeforeRelease
        )
        continuation.resume()
      }
    }
    publishPlaybackState(.idle)
    currentMedia = nil
  }

  /// The one place the native teardown choreography exists: bridge
  /// invalidation must precede the release (the event manager must be
  /// valid while detaching callbacks), the stop must precede the release
  /// (releasing a playing handle is undefined), and the drawables must
  /// outlive the release (the vout thread reads `drawable-nsobject`
  /// until the vout is torn down). Shared by `deinit` and
  /// ``shutdown()``.
  nonisolated static func teardownNativePlayer(
    _ pointer: OpaquePointer,
    bridge: EventBridge,
    retainedDrawables: [AnyObject],
    resumeBeforeStop: Bool
  ) {
    bridge.invalidate()
    stopNativePlayerBeforeRelease(pointer, resumeBeforeStop: resumeBeforeStop)
    libvlc_media_player_release(pointer)
    _ = retainedDrawables
  }

  /// Re-applies per-player state that lives on the native handle and
  /// would otherwise silently reset across a replacement: overlay
  /// (marquee/logo) configuration, video adjustments, stereo/mix modes,
  /// and the shadowed teletext page, deinterlace filter, audio output
  /// routing, and 360° viewpoint.
  ///
  /// Marquee text comes from the `_marqueeText` shadow, never from the
  /// old handle — a cache-bust write may be in flight there, and the live
  /// value would capture its transient garbage. A-B loop bounds,
  /// track/chapter/title selection, and DVB program selection are
  /// deliberately *not* carried: loop bounds are meaningless against a
  /// new session, and elementary-stream/program ids can differ per
  /// session, so re-selection is app policy.
  func carryOverPerPlayerState(from oldPointer: OpaquePointer, to newPointer: OpaquePointer) {
    let marqueeIntOptions: [libvlc_video_marquee_option_t] = [
      libvlc_marquee_Color, libvlc_marquee_Opacity, libvlc_marquee_Size,
      libvlc_marquee_X, libvlc_marquee_Y, libvlc_marquee_Timeout,
      libvlc_marquee_Refresh, libvlc_marquee_Position, libvlc_marquee_Enable
    ]
    if !_marqueeText.isEmpty {
      libvlc_video_set_marquee_string(
        newPointer,
        UInt32(libvlc_marquee_Text.rawValue),
        _marqueeText
      )
    }
    for option in marqueeIntOptions {
      libvlc_video_set_marquee_int(
        newPointer,
        UInt32(option.rawValue),
        libvlc_video_get_marquee_int(oldPointer, UInt32(option.rawValue))
      )
    }

    if let _logoFile {
      libvlc_video_set_logo_string(newPointer, UInt32(libvlc_logo_file.rawValue), _logoFile)
    }
    let logoIntOptions: [libvlc_video_logo_option_t] = [
      libvlc_logo_x, libvlc_logo_y, libvlc_logo_opacity,
      libvlc_logo_delay, libvlc_logo_repeat, libvlc_logo_position,
      libvlc_logo_enable
    ]
    for option in logoIntOptions {
      libvlc_video_set_logo_int(
        newPointer,
        UInt32(option.rawValue),
        libvlc_video_get_logo_int(oldPointer, UInt32(option.rawValue))
      )
    }

    let adjustFloatOptions: [libvlc_video_adjust_option_t] = [
      libvlc_adjust_Contrast, libvlc_adjust_Brightness, libvlc_adjust_Hue,
      libvlc_adjust_Saturation, libvlc_adjust_Gamma
    ]
    for option in adjustFloatOptions {
      libvlc_video_set_adjust_float(
        newPointer,
        UInt32(option.rawValue),
        libvlc_video_get_adjust_float(oldPointer, UInt32(option.rawValue))
      )
    }
    libvlc_video_set_adjust_int(
      newPointer,
      UInt32(libvlc_adjust_Enable.rawValue),
      libvlc_video_get_adjust_int(oldPointer, UInt32(libvlc_adjust_Enable.rawValue))
    )

    libvlc_audio_set_stereomode(newPointer, libvlc_audio_get_stereomode(oldPointer))
    libvlc_audio_set_mixmode(newPointer, libvlc_audio_get_mixmode(oldPointer))

    if let _teletextPage {
      libvlc_video_set_teletext(newPointer, _teletextPage)
    }
    if let _deinterlaceState {
      _ = libvlc_video_set_deinterlace(newPointer, _deinterlaceState, _deinterlaceMode)
    }
    if let _audioOutputModule {
      _ = libvlc_audio_output_set(newPointer, _audioOutputModule)
    }
    if let _audioOutputDevice {
      _ = libvlc_audio_output_device_set(newPointer, _audioOutputDevice)
    }
    if let _viewpoint, let vp = libvlc_video_new_viewpoint() {
      defer { free(vp) }
      vp.pointee.f_yaw = _viewpoint.yaw
      vp.pointee.f_pitch = _viewpoint.pitch
      vp.pointee.f_roll = _viewpoint.roll
      vp.pointee.f_field_of_view = _viewpoint.fieldOfView
      _ = libvlc_video_update_viewpoint(newPointer, vp, true)
    }
  }
}
