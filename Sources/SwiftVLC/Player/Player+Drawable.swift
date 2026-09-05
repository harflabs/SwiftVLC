import CLibVLC

#if os(iOS)
extension Player {
  #if DEBUG
  static var _nativePiPIdentityPublicationOverrideForTesting:
    ((OpaquePointer, UInt64, UInt64) -> Bool)?
  static var _nativePiPV9AvailabilityOverrideForTesting: Bool?
  #endif

  static var nativePiPHandoffV9Available: Bool {
    #if DEBUG
    if let override = _nativePiPV9AvailabilityOverrideForTesting {
      return override
    }
    #endif
    return swiftvlc_native_pip_handoff_v9_available()
  }

  /// Publishes the process-unique lifetime identity and playback generation as
  /// one native snapshot. Version-8 archives return false without mutation.
  @discardableResult
  static func publishNativePiPPlaybackIdentity(
    on pointer: OpaquePointer,
    playbackGeneration: UInt64,
    nativeHandleIdentity: UInt64
  ) -> Bool {
    precondition(nativeHandleIdentity != 0)
    precondition(playbackGeneration != 0)
    #if DEBUG
    if let override = _nativePiPIdentityPublicationOverrideForTesting {
      return override(pointer, playbackGeneration, nativeHandleIdentity)
    }
    #endif
    return swiftvlc_media_player_set_pip_playback_identity_if_available(
      pointer,
      nativeHandleIdentity,
      playbackGeneration
    )
  }
}
#endif

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
enum NativePlayerReplacementRenderer {
  case configured
  case explicit(RendererItem?)
}

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
    // A shut-down player must not bind a new video output. Detaching stays
    // allowed so a view tearing down after shutdown still clears cleanly, and
    // so shutdown's own `drawable = nil` path is unaffected.
    if isShutdown, newDrawable != nil {
      return
    }
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
    guard nativeHandleRepresentsCurrentMedia else {
      // `load(B)` can publish B while A is still attached and draining. The
      // drawable is successor configuration in that interval; writing A's
      // native nsobject would relabel its output and can hand it B's view.
      return
    }
    if newDrawable != nil {
      nativePlayerHasHostedDrawable = true
    }
    libvlc_media_player_set_nsobject(
      pointer,
      newDrawable.map { Unmanaged.passUnretained($0).toOpaque() }
    )
    _ = previous
  }

  func prepareDrawableForPlayback(
    successorPlaybackGeneration: PlaybackGeneration? = nil,
    playbackGenerationIsAlreadyCommitted: Bool = false
  )
    throws(VLCError) {
    if nativePlayerNeedsReplacementBeforePlayback {
      try replaceNativePlayerForDrawablePlayback(
        target: drawable,
        successorPlaybackGeneration: successorPlaybackGeneration,
        playbackGenerationIsAlreadyCommitted:
        playbackGenerationIsAlreadyCommitted
      )
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

  /// Swaps in a fresh native handle, carrying the current per-player state
  /// across.
  ///
  /// Atomic on failure: the only throwing step happens before anything on
  /// `self` is mutated, so a rejected renderer leaves the outgoing handle
  /// playing and every Swift-side field untouched.
  ///
  /// - Parameter media: The media to install on the new handle. Pass this
  ///   explicitly when replacing *as part of* loading new media, so the
  ///   caller can publish `currentMedia` only after the swap succeeds and a
  ///   failure cannot leave public state describing media the player is not
  ///   playing. Defaults to the already-published ``currentMedia``.
  /// - Parameter successorPlaybackGeneration: When this replacement starts a
  ///   new playback session, the generation to commit before the successor can
  ///   play. Leaving this `nil` preserves the current playback generation.
  /// - Parameter playbackGenerationIsAlreadyCommitted: Pass `true` only when
  ///   `successorPlaybackGeneration` is the EventBridge's exact current value;
  ///   replacement then carries it to the new handle without advancing again.
  @discardableResult
  func replaceNativePlayerForDrawablePlayback(
    target: AnyObject?,
    media: Media? = nil,
    resumeBeforeRelease: Bool = false,
    successorPlaybackGeneration: PlaybackGeneration? = nil,
    playbackGenerationIsAlreadyCommitted: Bool = false,
    renderer: NativePlayerReplacementRenderer = .configured,
    recastExpectation: RecastReplacementExpectation? = nil
  )
    throws(VLCError) -> RecastReplacementCommitResult? {
    let oldPointer = pointer
    let oldLifetime = nativeHandleLifetime
    let outgoingNativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let replacementMedia = media ?? currentMedia
    let replacementRenderer: RendererItem? = switch renderer {
    case .configured: selectedRenderer
    case .explicit(let renderer): renderer
    }
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

    guard setNativeRenderer(replacementRenderer, on: newPointer) == 0 else {
      libvlc_media_player_release(newPointer)
      throw .operationFailed("Set renderer")
    }
    let newLifetime = NativePlayerHandleLifetime(pointer: newPointer)
    func releaseUncommittedCandidate() {
      libvlc_media_player_release(newPointer)
      newLifetime.initialOwnerDidRelease()
    }
    do {
      try reattachTextSubtitleCaptureIfEnabled(to: newLifetime)
    } catch {
      releaseUncommittedCandidate()
      throw error
    }
    #if os(iOS)
    let identityGeneration = successorPlaybackGeneration?.value ?? sessionGeneration
    if
      Self.nativePiPHandoffV9Available,
      replacementMedia != nil,
      identityGeneration == 0 {
      releaseUncommittedCandidate()
      throw .operationFailed("Publish native PiP playback identity")
    }
    let didPublishPiPIdentity = identityGeneration != 0
      ? Self.publishNativePiPPlaybackIdentity(
        on: newPointer,
        playbackGeneration: identityGeneration,
        nativeHandleIdentity: newLifetime.nativePiPHandleIdentity
      )
      : false
    if
      Self.nativePiPHandoffV9Available,
      identityGeneration != 0,
      !didPublishPiPIdentity {
      releaseUncommittedCandidate()
      throw .operationFailed("Publish native PiP playback identity")
    }
    #endif
    if let incoming = replacementMedia {
      libvlc_media_player_set_media(newPointer, incoming.pointer)
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

    guard
      let preparedReattachment = eventBridge.prepareReattachment(
        to: newEventManager
      ) else {
      releaseUncommittedCandidate()
      throw .operationFailed("Attach player events")
    }

    let replacementCommitResult: RecastReplacementCommitResult?
    let committedSuccessorPlaybackGeneration: PlaybackGeneration?
    if let recastExpectation {
      precondition(!playbackGenerationIsAlreadyCommitted)
      guard let successorPlaybackGeneration else {
        preconditionFailure("A recast replacement must advance playback generation")
      }
      guard
        attachedMediaListPlayer == nil,
        mediaListOwnershipEpoch == recastExpectation.ownershipEpoch
      else {
        eventBridge.cancelPreparedReattachment(preparedReattachment)
        releaseUncommittedCandidate()
        return .interrupted(.superseded)
      }
      let result = eventBridge.commitRecastReplacementIfCurrent(
        expectation: recastExpectation,
        successorPlaybackGeneration: successorPlaybackGeneration.value,
        preparedReattachment: preparedReattachment
      )
      switch result {
      case .committed(let lease):
        replacementCommitResult = result
        committedSuccessorPlaybackGeneration = PlaybackGeneration(
          lease.playbackGeneration
        )
      case .interrupted:
        eventBridge.cancelPreparedReattachment(preparedReattachment)
        releaseUncommittedCandidate()
        return result
      }
    } else {
      replacementCommitResult = nil
      committedSuccessorPlaybackGeneration = successorPlaybackGeneration.map {
        if playbackGenerationIsAlreadyCommitted {
          precondition(
            eventBridge.currentPlaybackGeneration == $0.value,
            "Already-committed replacement generation must match EventBridge"
          )
          return $0
        }
        return PlaybackGeneration(eventBridge.synchronizePlaybackGeneration(
          $0.value,
          media: replacementMedia?.pointer,
          outgoingNativeHandleGeneration: outgoingNativeHandleGeneration
        ))
      }
    }

    // Renderer choice is part of the replacement transaction's identity, not
    // post-commit bookkeeping. Commit an explicit choice only after every
    // throwing/rejecting boundary above has succeeded, and before any native
    // call or observable mutation below can synchronously reenter app code and
    // install a newer successor. A later takeover then inherits this committed
    // choice instead of the predecessor's stale renderer.
    if case .explicit(let renderer) = renderer {
      selectedRenderer = renderer
    }

    // No callback or stop can take the outgoing lifecycle after this point.
    // Install the fully attached candidate while its token remains inactive.
    // Old-listener detach is the quiescence boundary, and the successor cannot
    // emit until every Swift/native identity below describes that successor.
    let nativeHandleGeneration = eventBridge.installPreparedReattachment(
      preparedReattachment
    )
    // Keep the successor alive across native calls which can synchronously
    // reenter app code (notably AVAudioSession lease transfer). A nested
    // load/play may retire B while that native call is still on the stack.
    // The matching retain is released before the first observable boundary.
    let successorNativeWorkLease = newLifetime.acquireNativeOwnerLease()
    _ = libvlc_media_player_retain(newPointer)
    #if os(iOS) || os(macOS)
    // This API intentionally runs while `nativeHandleLifetime` still names the
    // predecessor; it validates and retires that exact slot before binding the
    // candidate slot.
    moveDirectPiPVideoCallbacks(to: newLifetime)
    #endif

    // These are transaction identity, not observable facts. EventBridge's
    // candidate is still inactive and the old callbacks are detached, so no
    // callback can observe the otherwise unavoidable pointer/lifetime writes
    // independently. The native seek watcher must move before changing
    // `sessionGeneration`: its didSet rotates the current watcher, which must
    // already be attached to this successor rather than briefly relabelling A
    // as B.
    pointer = newPointer
    nativeHandleLifetime = newLifetime
    supersedeAllSeekWorkForCausalBoundary()
    let drainedFrameResults = nativeSeekMonitor.reattach(
      to: newPointer,
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: committedSuccessorPlaybackGeneration?.value
        ?? sessionGeneration
    )
    settleFrameStepsAfterAttachmentRetirement(
      drainedResults: drainedFrameResults
    )
    if let committedSuccessorPlaybackGeneration {
      sessionGeneration = committedSuccessorPlaybackGeneration.value
      sessionGenerationMedia = replacementMedia?.pointer
    }
    let installedPlaybackGeneration = committedSuccessorPlaybackGeneration?.value
      ?? sessionGeneration
    func stillOwnsInstalledSuccessor() -> Bool {
      pointer == newPointer
        && nativeHandleLifetime === newLifetime
        && sessionGeneration == installedPlaybackGeneration
        && eventBridge.currentPlaybackGeneration == installedPlaybackGeneration
        && eventBridge.currentNativeHandleGeneration == nativeHandleGeneration
    }
    nativePlayerNeedsReplacementBeforePlayback = false
    nativePlayerReplacementHasCommittedMediaGeneration = false
    needsDrawableRebindForPlayback = false
    nativePlayerHasHostedDrawable = target != nil
    nativePlaybackStartWasObserved = false
    #if os(iOS)
    if
      let committedSuccessorPlaybackGeneration,
      let attachment = target as? IOSNativePiPDrawableAttachment {
      // Publish the successor only after Swift's pointer, native lifetime,
      // EventBridge, and playback generation all describe that successor,
      // while the predecessor handle is still retained below.
      attachment.expectPictureInPictureHandoff(
        to: IOSNativePiPPlaybackBinding(
          nativeHandle: newLifetime.nativePiPHandleIdentity,
          playbackGeneration: committedSuccessorPlaybackGeneration
        )
      )
    }
    #endif

    #if os(iOS) || os(macOS)
    // The successor direct-callback slot, pointer, lifetime, EventBridge
    // generation, and playback generation are coherent before any callback
    // snapshot can publish the handle.
    refreshNativeHandleSnapshots()
    #endif

    #if DEBUG
    _nativePlayerReplacementWillActivateForTesting?()
    #endif
    eventBridge.activatePreparedReattachment(preparedReattachment)

    // Finish every operation that dereferences the successor before the first
    // public observable mutation. Observation callbacks are synchronous: an
    // observer may load and play C at that first boundary, replacing and
    // releasing B before this outer transaction resumes.
    let transferredManagedAudioSessionLease =
      transferManagedAppleAudioSessionLease(to: newPointer)
    if
      stillOwnsInstalledSuccessor(),
      transferredManagedAudioSessionLease == false {
      invalidateManagedAppleAudioSessionActivationLatches()
    }
    if stillOwnsInstalledSuccessor() {
      attachedMediaListPlayer?.rebindMediaPlayerHandle()
    }
    if stillOwnsInstalledSuccessor() {
      applyAspectRatio()
      retainedDrawablesUntilNativePlayerRelease.removeAll()
    }

    #if DEBUG
    _nativePlayerReplacementWillReleaseOldHandleForTesting?()
    #endif

    libvlc_media_player_release(newPointer)
    successorNativeWorkLease.endAfterNativeOwnerRelease()
    releaseNativePlayer(
      oldPointer,
      lifetime: oldLifetime,
      retaining: retainedDrawables,
      resumeBeforeStop: resumeBeforeRelease
    )
    let didResetActiveVideoOutputs = performObservableMutation(
      keyPath: \.activeVideoOutputs,
      ifPlaybackGeneration: installedPlaybackGeneration,
      nativeHandleGeneration: nativeHandleGeneration
    ) {
      storeActiveVideoOutputsWithoutNestedObservation(0)
    }
    if didResetActiveVideoOutputs {
      _ = notifyMediaDependentObservables(
        ifPlaybackGeneration: installedPlaybackGeneration
      )
    }
    eventBridge.publishRetiredNaturalEndsAfterHandleReplacement()
    return replacementCommitResult
  }
}
