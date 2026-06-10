import CLibVLC

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
    // Bind the outgoing reference to a local so it outlives the libVLC
    // call. After the ivar is reassigned, ARC would otherwise release
    // the previous view immediately; the vout thread could still be
    // mid-deref of that `drawable-nsobject` pointer. `previous`
    // keeps the previous view alive until this function returns, by which
    // point libVLC has atomically swapped the variable.
    let previous = drawable
    if
      let previous,
      nativePlayerNeedsReplacementBeforePlayback,
      newDrawable.map({ previous !== $0 }) ?? true {
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

  func replaceNativePlayerForDrawablePlayback(
    target: AnyObject?,
    resumeBeforeRelease: Bool = false
  )
    throws(VLCError) {
    let oldPointer = pointer
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
    let retainedDrawables = retainedDrawablesUntilNativePlayerRelease

    if let currentMedia {
      libvlc_media_player_set_media(newPointer, currentMedia.pointer)
    }
    guard libvlc_media_player_set_renderer(newPointer, selectedRenderer?.pointer) == 0 else {
      libvlc_media_player_release(newPointer)
      throw .operationFailed("Set renderer")
    }
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
    pointer = newPointer
    attachedMediaListPlayer?.rebindMediaPlayerHandle()
    applyAspectRatio()

    retainedDrawablesUntilNativePlayerRelease.removeAll()
    nativePlayerNeedsReplacementBeforePlayback = false
    needsDrawableRebindForPlayback = false
    nativePlayerHasHostedDrawable = target != nil
    nativePlayerHasStartedPlayback = false

    releaseNativePlayer(
      oldPointer,
      retaining: retainedDrawables,
      resumeBeforeStop: resumeBeforeRelease
    )
    notifyMediaDependentObservables()
  }
}
