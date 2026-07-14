import CLibVLC

#if os(macOS)
@MainActor
struct MacVideoOutputRecovery {
  let expectedTrackID: String
  let maximumDeselectionPolls: Int
  let playbackIsCurrent: @MainActor () -> Bool
  let playbackState: @MainActor () -> PlayerState
  let selectedTrackID: @MainActor () -> String?
  let waitForDeselection: @MainActor () async -> Void
  let reselectTrack: @MainActor (String) -> Void

  init(
    expectedTrackID: String,
    maximumDeselectionPolls: Int = 50,
    playbackIsCurrent: @escaping @MainActor () -> Bool,
    playbackState: @escaping @MainActor () -> PlayerState,
    selectedTrackID: @escaping @MainActor () -> String?,
    waitForDeselection: @escaping @MainActor () async -> Void,
    reselectTrack: @escaping @MainActor (String) -> Void
  ) {
    self.expectedTrackID = expectedTrackID
    self.maximumDeselectionPolls = maximumDeselectionPolls
    self.playbackIsCurrent = playbackIsCurrent
    self.playbackState = playbackState
    self.selectedTrackID = selectedTrackID
    self.waitForDeselection = waitForDeselection
    self.reselectTrack = reselectTrack
  }

  func run() async {
    for _ in 0..<maximumDeselectionPolls {
      guard playbackIsCurrent() else { return }
      guard let selectedTrackID = selectedTrackID() else { break }
      guard selectedTrackID == expectedTrackID else { return }
      await waitForDeselection()
    }

    guard playbackIsCurrent() else { return }
    switch playbackState() {
    case .idle, .stopped, .stopping, .error:
      return
    case .opening, .buffering, .playing, .paused:
      break
    }

    if let selectedTrackID = selectedTrackID() {
      guard selectedTrackID == expectedTrackID else { return }
    }
    reselectTrack(expectedTrackID)
  }
}

@MainActor
struct MacVideoOutputRecoveryNativeOperations {
  let selectedTrackID: @MainActor (OpaquePointer) -> String?
  let unselectVideoTrack: @MainActor (OpaquePointer) -> Void
  let reselectVideoTrack: @MainActor (OpaquePointer, String) -> Void
  let waitForDeselection: @MainActor () async -> Void

  static var live: Self {
    Self(
      selectedTrackID: selectedVideoTrackID(for:),
      unselectVideoTrack: {
        libvlc_media_player_unselect_track_type($0, libvlc_track_video)
      },
      reselectVideoTrack: { player, trackID in
        trackID.withCString { id in
          libvlc_media_player_select_tracks_by_ids(player, libvlc_track_video, id)
        }
      },
      waitForDeselection: {
        try? await Task.sleep(for: .milliseconds(10))
      }
    )
  }
}

private func selectedVideoTrackID(for player: OpaquePointer) -> String? {
  libvlc_media_player_get_selected_track(player, libvlc_track_video)
    .flatMap(nativeTrackID(adopting:))
}

func nativeTrackID(adopting track: UnsafeMutablePointer<libvlc_media_track_t>) -> String? {
  defer { libvlc_media_track_release(track) }
  return track.pointee.psz_id.map(String.init(cString:))
}
#endif

/// Platform-drawable attachment and the lazy native-handle replacement
/// it requires after stopped drawable-hosted playback.
extension Player {
  // MARK: - Video Drawable

  /// Attaches (or detaches, when `nil`) the platform-native view that
  /// libVLC renders video into. `Player` holds the view strongly for
  /// the duration of the attachment so libVLC's raw `drawable-nsobject`
  /// pointer stays valid against asynchronous reads from the decode
  /// thread. Callers should normally use ``VideoView`` in SwiftUI; this
  /// is the lower-level API it builds on.
  func setDrawable(_ newDrawable: AnyObject?) {
    drawableOwner = newDrawable.map(ObjectIdentifier.init)
    applyDrawable(newDrawable)
  }

  func claimDrawableOwnership(_ owner: AnyObject) {
    drawableOwner = ObjectIdentifier(owner)
  }

  func releaseDrawableOwnership(_ owner: AnyObject) {
    guard isDrawableOwner(owner) else { return }
    drawableOwner = nil
    if isCurrentDrawable(owner) {
      applyDrawable(nil)
    }
  }

  func setDrawable(_ newDrawable: AnyObject, owner: AnyObject) {
    guard isDrawableOwner(owner) else { return }
    applyDrawable(newDrawable)
  }

  func clearDrawable(ifCurrent staleDrawable: AnyObject) {
    guard isCurrentDrawable(staleDrawable) else { return }
    if drawableOwner == ObjectIdentifier(staleDrawable) {
      drawableOwner = nil
    }
    setDrawable(nil)
  }

  func isCurrentDrawable(_ candidate: AnyObject) -> Bool {
    guard let drawable else { return false }
    return drawable === candidate
  }

  func isDrawableOwner(_ candidate: AnyObject) -> Bool {
    drawableOwner == ObjectIdentifier(candidate)
  }

  func applyDrawable(_ newDrawable: AnyObject?) {
    // libVLC stores `drawable-nsobject` as a raw pointer. Once this exact
    // handle has started, replacing the variable cannot revoke a pointer an
    // opening or draining vout already copied. Retain every outgoing drawable
    // until that handle is released; the replacement/shutdown/deinit paths
    // move this array into the closure that performs the native release.
    //
    // Before first playback there is no vout, so the local `previous` retain
    // only needs to cover libVLC's synchronous variable swap.
    let previous = drawable
    if
      let previous,
      nativePlayerHasStartedPlayback || nativePlayerNeedsReplacementBeforePlayback,
      newDrawable.map({ previous !== $0 }) ?? true,
      !retainedDrawablesUntilNativePlayerRelease.contains(where: { $0 === previous }) {
      retainedDrawablesUntilNativePlayerRelease.append(previous)
    }
    drawable = newDrawable
    if newDrawable != nil {
      nativePlayerHasHostedDrawable = true
    }
    libvlc_media_player_set_nsobject(
      pointer,
      newDrawable.map { Unmanaged.passUnretained($0).toOpaque() }
    )
    _ = previous
  }

  func prepareDrawableForPlayback() throws(VLCError) {
    if nativePlayerNeedsReplacementBeforePlayback {
      try replaceNativePlayerForDrawablePlayback(target: drawable)
      return
    }
    guard let target = drawable else { return }
    guard needsDrawableRebindForPlayback else { return }
    let owner = drawableOwner
    applyDrawable(nil)
    drawableOwner = owner
    applyDrawable(target)
    needsDrawableRebindForPlayback = false
  }

  #if os(macOS)
  /// Reopens the active video output after its AppKit drawable moves between
  /// windows. `VLCOpenGLVideoView` owns an `NSOpenGLContext` whose window
  /// surface can become invalid when macOS destroys the old PiP window even
  /// though decoding and audio continue. Re-selecting the same video track
  /// rebuilds only that output against the drawable's new inline window.
  @discardableResult
  func reopenVideoOutputAfterDrawableWindowMove(
    using native: MacVideoOutputRecoveryNativeOperations = .live
  ) -> Task<Void, Never>? {
    guard
      let media = currentMedia,
      let trackID = native.selectedTrackID(pointer)
    else { return nil }

    let nativePlayer = pointer
    native.unselectVideoTrack(nativePlayer)

    return Task { @MainActor [weak self, weak media] in
      guard let self else { return }

      // Track selection is processed asynchronously by libVLC. Wait for the
      // deselection to settle so selecting the same ID cannot be coalesced
      // into a no-op that leaves the invalid OpenGL surface alive. Some VLC
      // inputs keep their vout allocated while no video track is selected, so
      // the selected-track state is the reliable acknowledgement here.
      await MacVideoOutputRecovery(
        expectedTrackID: trackID,
        playbackIsCurrent: { [weak self, weak media] in
          guard let self, let media else { return false }
          return pointer == nativePlayer && currentMedia === media
        },
        playbackState: { [weak self] in self?.state ?? .idle },
        selectedTrackID: { native.selectedTrackID(nativePlayer) },
        waitForDeselection: {
          await native.waitForDeselection()
        },
        reselectTrack: { trackID in
          native.reselectVideoTrack(nativePlayer, trackID)
        }
      ).run()
    }
  }
  #endif

  func replaceNativePlayerForDrawablePlayback(
    target: AnyObject?,
    resumeBeforeRelease: Bool = false
  )
    throws(VLCError) {
    let oldPointer = pointer
    let oldLifetime = nativeHandleLifetime
    let newPointer = Self.makeNativePlayer(instance: instance)
    guard let newEventManager = libvlc_media_player_event_manager(newPointer) else {
      libvlc_media_player_release(newPointer)
      preconditionFailure("Failed to access libVLC media player event manager.")
    }

    let playbackRate = libvlc_media_player_get_rate(oldPointer)
    let playerRole = libvlc_media_player_get_role(oldPointer)
    let audioDelay = libvlc_audio_get_delay(oldPointer)
    let subtitleDelay = libvlc_video_get_spu_delay(oldPointer)
    let subtitleScale = libvlc_video_get_spu_text_scale(oldPointer)
    // The outgoing handle may already have copied `target` into an opening or
    // draining vout. The successor's strong drawable reference is not a lease
    // for that predecessor: its teardown runs independently and can finish
    // first. Charge the current target to the exact outgoing lifetime, just as
    // shutdown/deinit do, so rapid replacements cannot release it out of
    // generation order.
    var retainedDrawables = retainedDrawablesUntilNativePlayerRelease
    if
      let target,
      !retainedDrawables.contains(where: { $0 === target }) {
      retainedDrawables.append(target)
    }

    if let currentMedia {
      libvlc_media_player_set_media(newPointer, currentMedia.pointer)
    }
    guard libvlc_media_player_set_renderer(newPointer, selectedRenderer?.pointer) == 0 else {
      libvlc_media_player_release(newPointer)
      throw .operationFailed("Set renderer")
    }
    let newLifetime = NativePlayerHandleLifetime(pointer: newPointer)
    _ = libvlc_audio_set_volume(newPointer, Int32(_volume * 100))
    libvlc_audio_set_mute(newPointer, _isMuted ? 1 : 0)
    _ = libvlc_media_player_set_rate(newPointer, playbackRate)
    _ = libvlc_media_player_set_role(newPointer, UInt32(playerRole))
    _ = libvlc_audio_set_delay(newPointer, audioDelay)
    _ = libvlc_video_set_spu_delay(newPointer, subtitleDelay)
    libvlc_video_set_spu_text_scale(newPointer, subtitleScale)
    libvlc_media_player_set_equalizer(newPointer, _equalizer?.pointer)
    libvlc_media_player_set_nsobject(
      newPointer,
      target.map { Unmanaged.passUnretained($0).toOpaque() }
    )

    carryOverPerPlayerState(from: oldPointer, to: newPointer)

    eventBridge.reattach(to: newEventManager)
    // The old handle's terminal events are unobservable from here on; a
    // pending stop/error cause would otherwise outlive its `Stopped` and
    // suppress the next genuine natural end. The same applies to its
    // closing `voutChanged(0)` — the source filter drops it after the
    // reattach — so reset the mirrored output count here instead of
    // leaving it pinned to the dead handle's outputs.
    endCoordinator.clearForHandleReplacement()
    activeVideoOutputs = 0
    #if os(iOS) || os(macOS)
    moveDirectPiPVideoCallbacks(to: newLifetime)
    #endif
    pointer = newPointer
    nativeHandleLifetime = newLifetime
    attachedMediaListPlayer?.rebindMediaPlayerHandle()
    applyAspectRatio()

    retainedDrawablesUntilNativePlayerRelease.removeAll()
    nativePlayerNeedsReplacementBeforePlayback = false
    needsDrawableRebindForPlayback = false
    nativePlayerHasHostedDrawable = target != nil
    nativePlayerHasStartedPlayback = false

    releaseNativePlayer(
      oldPointer,
      lifetime: oldLifetime,
      retaining: retainedDrawables,
      resumeBeforeStop: resumeBeforeRelease
    )
    notifyMediaDependentObservables()
  }
}
