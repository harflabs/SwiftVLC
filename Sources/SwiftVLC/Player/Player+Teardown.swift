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
  /// new-session readiness instead. A defensive 10-second ceiling keeps a
  /// wedged pipeline from hanging the caller.
  ///
  /// Only ``PlayerStopOutcome/stopped`` means the outputs were released.
  /// A native error is **not** treated as completion: libVLC reports the
  /// error first and the stopped state that performs the release arrives
  /// afterwards, so this keeps waiting and reports
  /// ``PlayerStopOutcome/failedButStillDraining`` if that follow-up never
  /// comes. Check the result — or ``PlayerStopOutcome/isOutputSafe`` —
  /// before deactivating an audio session or detaching a drawable.
  ///
  /// Concurrent callers join one in-flight stop and all receive the same
  /// outcome. Cancelling a caller does not abandon the drain; the stop runs
  /// to completion so no caller is ever told the outputs are free while
  /// they are still live.
  ///
  /// - Returns: Why the wait ended. Only ``PlayerStopOutcome/stopped``
  ///   establishes that the outputs were released; test it directly or
  ///   through ``PlayerStopOutcome/isOutputSafe`` rather than treating a
  ///   returned value as a success flag.
  @discardableResult
  public func stopAndWait() async -> PlayerStopOutcome {
    // Concurrent callers join one in-flight stop and all observe the same
    // outcome; a second caller must not be told the outputs are released
    // just because someone else asked first.
    if let inFlight = stopAndWaitTask {
      return await inFlight.value
    }
    let task = Task { @MainActor [self] in
      let outcome = await performStopAndWait()
      stopAndWaitTask = nil
      return outcome
    }
    stopAndWaitTask = task
    return await task.value
  }

  private func performStopAndWait() async -> PlayerStopOutcome {
    // `.error` is deliberately absent here. libVLC reports the error first
    // and the stopped state that actually releases the outputs afterwards
    // (see `PlayerEndReachedTests`), so returning on `.error` would promise
    // output safety while the outputs are still draining.
    switch nativePlaybackState {
    case .idle, .stopped:
      stop()
      return .stopped
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
    case .idle, .stopped:
      stop()
      return .stopped
    default:
      break
    }
    stop()
    let outcome = await Self.awaitOutputSafeStop(on: stream, source: source)
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
    return Self.resolveStopOutcome(waitOutcome: outcome, nativeState: terminal)
  }

  /// Folds the native handle's resting state into the wait's verdict.
  ///
  /// A wait that ended without a stop means one of two different things, and
  /// the caller needs them distinguished: the pipeline is merely slow, or the
  /// session errored and the stop that releases the outputs never followed.
  ///
  /// Pure so the rule is testable without live playback, which CI cannot
  /// drive (see `TestCondition.canPlayMedia`).
  nonisolated static func resolveStopOutcome(
    waitOutcome: PlayerStopOutcome,
    nativeState: PlayerState
  )
    -> PlayerStopOutcome {
    if waitOutcome == .timedOut, nativeState == .error {
      return .failedButStillDraining
    }
    return waitOutcome
  }

  /// Waits for the *output-safe* terminal state and reports why the wait
  /// ended.
  ///
  /// Only `.stopped` releases the outputs. An observed `.error` is recorded
  /// but does not end the wait, because libVLC emits the error before the
  /// stopped state that performs the release; if no stopped state follows
  /// within the ceiling, the error is what the caller needs to hear about.
  /// - Parameter timeout: The defensive ceiling. Injectable so the decision
  ///   logic can be exercised against a synthetic event stream, without
  ///   needing live playback — CI cannot drive libVLC to `.playing`
  ///   (see `TestCondition.canPlayMedia`).
  nonisolated static func awaitOutputSafeStop(
    on stream: AsyncStream<SourcedPlayerEvent>,
    source: UInt,
    timeout: Duration = .seconds(10)
  )
    async -> PlayerStopOutcome {
    await withTaskGroup(of: PlayerStopOutcome?.self) { group in
      group.addTask {
        for await sourced in stream {
          guard
            sourced.source == source,
            case .stateChanged(let state) = sourced.event
          else { continue }
          // Only `.stopped` ends the wait. An `.error` is ignored here: the
          // release happens on the stopped state that follows it, and the
          // caller learns about a stuck error from the native state read
          // back in `performStopAndWait()`.
          if state == .stopped {
            return .stopped
          }
        }
        // The stream finished without a stopped state.
        return nil
      }
      group.addTask {
        // This child only ends early when the group is cancelled after a
        // verdict was already taken, so either way "no stop observed" is the
        // honest report. The stop task itself is unstructured and is never
        // cancelled by a caller, which is what keeps the drain protected.
        try? await Task.sleep(for: timeout)
        return .timedOut
      }
      let outcome: PlayerStopOutcome = switch await group.next() {
      case .some(.some(let first)):
        first
      default:
        // The observer's stream finished without ever reporting a stop.
        .timedOut
      }
      if outcome == .timedOut {
        #if DEBUG
        Signposts.signposter.emitEvent("Player.stopAndWait.timeout")
        #endif
      }
      group.cancelAll()
      return outcome
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
  /// Concurrent callers all join the *same* teardown: the first caller
  /// installs the task, every other caller awaits it, and none of them
  /// returns before the native handle has actually been released. Returning
  /// early on the flag alone would let a second caller observe a player that
  /// still has a draining libVLC thread, which is precisely what this
  /// method's contract promises is impossible.
  public func shutdown() async {
    if let inFlight = shutdownTask {
      await inFlight.value
      return
    }
    // Set before the task is created — and therefore before any suspension —
    // so commands issued from now on already see a retiring player.
    isShutdown = true
    let task = Task { @MainActor [self] in
      await performShutdown()
    }
    shutdownTask = task
    await task.value
  }

  private func performShutdown() async {
    // A still-attached list player would keep driving the handle being
    // torn down (its native binding retains it past the release) —
    // detach through the public setter so suppression and the native
    // binding are both released.
    if let listPlayer = attachedMediaListPlayer {
      listPlayer.mediaPlayer = nil
    }
    // Capture before the transition state is cleared below. The native
    // `.paused` event can lag a just-issued pause command, so consulting only
    // `nativePlaybackState` afterwards loses the race signal.
    let resumeBeforeRelease = shouldResumeNativePlayerBeforeStop
    publishPlaybackIntent(false)
    pauseTransition = nil
    deferredPauseCommand = nil
    eventTask?.cancel()
    eventTask = nil
    _marqueeRestoreTask?.cancel()
    // Permanent: `playbackIntentEvents` also subscribes per access, so a
    // post-shutdown subscriber must get an already-finished stream.
    playbackIntentBridge.terminate()
    libvlc_media_player_set_nsobject(pointer, nil)

    let bridge = eventBridge
    nonisolated(unsafe) let drawables =
      drawable.map { retainedDrawablesUntilNativePlayerRelease + [$0] }
        ?? retainedDrawablesUntilNativePlayerRelease
    nonisolated(unsafe) let p = pointer
    let lifetime = nativeHandleLifetime
    drawable = nil
    retainedDrawablesUntilNativePlayerRelease.removeAll()
    #if os(iOS) || os(macOS)
    retireDirectPiPVideoCallbacksForHandleEnd()
    #endif
    let replacement = Self.makeNativePlayer(instance: instance)
    let replacementLifetime = NativePlayerHandleLifetime(pointer: replacement)
    pointer = replacement
    nativeHandleLifetime = replacementLifetime

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .utility).async {
        Self.teardownNativePlayer(
          p,
          lifetime: lifetime,
          bridge: bridge,
          retainedDrawables: drawables,
          resumeBeforeStop: resumeBeforeRelease
        )
        continuation.resume()
      }
    }
    // `libvlc_media_player_release` only decrements a reference count. A
    // retiring MediaListPlayer can still own this exact handle after our own
    // release returns, so the full-teardown contract requires every counted
    // native owner to finish releasing before shutdown returns.
    await lifetime.waitUntilReleased()
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
    lifetime: NativePlayerHandleLifetime,
    bridge: EventBridge,
    retainedDrawables: [AnyObject],
    resumeBeforeStop: Bool
  ) {
    precondition(lifetime.pointer == pointer)
    lifetime.retainUntilReleased(retainedDrawables)
    bridge.invalidate()
    stopNativePlayerBeforeRelease(pointer, resumeBeforeStop: resumeBeforeStop)
    libvlc_media_player_release(pointer)
    lifetime.initialOwnerDidRelease()
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
