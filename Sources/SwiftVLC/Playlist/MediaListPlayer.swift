import CLibVLC
import Dispatch

enum MediaListPlayerNativeTransportCommand {
  case play
  case playAt(Int32)
  case playMedia(OpaquePointer)
  case stop
  case next
  case previous
}

private struct MediaListPlayerPlaybackStartReservation {
  nonisolated(unsafe) let nativeListPlayer: OpaquePointer
  let player: Player?
  nonisolated(unsafe) let nativePlayer: OpaquePointer?
  let nativeHandleGeneration: UInt64?
  let mediaListOwnershipEpoch: UInt64?
  let playbackControlRevision: UInt64?
  let playbackStartAttempt: EventBridgeCallbackContext.PlaybackStartAttempt?
}

/// A playlist player that plays media from a ``MediaList``.
///
/// Wraps `libvlc_media_list_player_t` and provides sequential, looping,
/// or repeating playback of a list of media items.
///
/// ```swift
/// let list = MediaList()
/// try list.append(media1)
/// try list.append(media2)
///
/// let listPlayer = MediaListPlayer()
/// listPlayer.mediaPlayer = Player()
/// listPlayer.mediaList = list
/// listPlayer.play()
/// ```
@MainActor
public final class MediaListPlayer {
  // `var` (not `let`) because `rebuildNativePlayer` swaps the underlying
  // libVLC handle when the media player or list is detached. Annotated
  // `nonisolated(unsafe)` to match every other libVLC pointer in the
  // codebase: reads happen on the @MainActor; the offload-on-deinit
  // closure binds the swapped pointer through its own
  // `nonisolated(unsafe) let oldPointer` capture.
  nonisolated(unsafe) var pointer: OpaquePointer // libvlc_media_list_player_t*
  private var _mediaPlayer: Player?
  /// Counted ownership matching the native retain performed by
  /// `libvlc_media_list_player_set_media_player`. It moves with the exact
  /// native list-player handle that owns that retain.
  private var nativePlayerBindingLease: NativePlayerHandleLease?
  private var _mediaList: MediaList?
  private var _playbackMode: PlaybackMode = .default
  private let instance: VLCInstance
  #if DEBUG
  var _nativeTransportDispatchOverrideForTesting:
    ((MediaListPlayerNativeTransportCommand) -> Int32)?
  #endif

  /// Creates a new media list player.
  /// - Parameter instance: The VLC instance to use.
  public init(instance: VLCInstance = .shared) {
    self.instance = instance
    guard let p = libvlc_media_list_player_new(instance.pointer) else {
      preconditionFailure("Failed to create libvlc media list player. Is the libvlc.xcframework linked correctly?")
    }
    pointer = p
  }

  isolated deinit {
    // A still-attached player must be released from suppression here, or
    // it never synthesizes a natural end again — the weak back-reference
    // nils silently and nothing else clears the flag. The offloaded stop
    // below drives the still-bound handle, so the same detach
    // bookkeeping as the setter applies.
    if let previous = _mediaPlayer {
      detachForEndSynthesis(previous)
    }
    // Release off the main actor. `stop_async` and `release` can block
    // waiting for VLC's internal threads, stalling all async work.
    nonisolated(unsafe) let p = pointer
    let bindingLease = nativePlayerBindingLease
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_list_player_stop_async(p)
      libvlc_media_list_player_release(p)
      bindingLease?.endAfterNativeOwnerRelease()
    }
  }

  /// The ``Player`` used for actual playback.
  ///
  /// While attached, the player does not synthesize
  /// ``PlayerEvent/endReached-enum.case`` — list advancement stops the
  /// handle
  /// between items through list-player C calls the player cannot tell
  /// apart from a natural end. Observe list-level completion instead.
  /// A player has one live list-player owner: assigning a player already
  /// attached elsewhere transfers it from the previous list player without
  /// stopping the shared native playback handle.
  public var mediaPlayer: Player? {
    get { _mediaPlayer }
    set {
      guard _mediaPlayer !== newValue else { return }
      // A committed successor can temporarily share Swift identity with a
      // still-bound retiring native handle. Binding a list player here would
      // let list navigation drive A while every public property describes B.
      guard
        newValue?.nativeHandleRepresentsCurrentMedia != false,
        newValue?.nativePlayerNeedsReplacementBeforePlayback != true else { return }

      if
        let newValue,
        let previousOwner = newValue.attachedMediaListPlayer,
        previousOwner !== self {
        previousOwner.detachForOwnershipTransfer(newValue)
      }

      let previous = _mediaPlayer
      if let newValue {
        let replacementLease = newValue.nativeHandleLifetime.acquireNativeOwnerLease()
        let previousLease = nativePlayerBindingLease
        libvlc_media_list_player_set_media_player(pointer, newValue.pointer)
        nativePlayerBindingLease = replacementLease
        previousLease?.endAfterNativeOwnerRelease()

        if let previous {
          detachForEndSynthesis(previous, nativeStopWillFollow: false)
        }
        _mediaPlayer = newValue
        newValue.endCoordinator.setSuppressed(true)
        newValue.transitionMediaListOwnership(to: self)
      } else {
        if let previous {
          detachForEndSynthesis(previous, nativeStopWillFollow: true)
        }
        _mediaPlayer = nil
        rebuildNativePlayer(stopSharedPlayerBeforeDetaching: true)
      }
    }
  }

  /// Detach-time terminal bookkeeping for a previously attached player. A nil
  /// detach or final list-player teardown stops the still-bound handle later,
  /// so it records that stop as requested before lifting raw-end suppression.
  /// Replacing or transferring an attachment does not stop the old player.
  /// Suppression is lifted unless another list player has since taken over.
  private func detachForEndSynthesis(
    _ previous: Player,
    nativeStopWillFollow: Bool = true
  ) {
    if nativeStopWillFollow {
      switch previous.nativePlaybackState {
      case .idle, .stopped, .error:
        break
      default:
        previous.eventBridge.markRequestedStop(
          playbackGeneration: previous.sessionGeneration
        )
      }
    }
    let owner = previous.attachedMediaListPlayer
    guard owner === self || owner == nil else { return }
    previous.endCoordinator.setSuppressed(false)
    previous.transitionMediaListOwnership(to: nil)
  }

  /// Re-binds the native list player to the attached ``Player``'s
  /// current handle. The C API stores the raw `libvlc_media_player_t*`,
  /// so the player calls this after every native-handle replacement —
  /// without it the list player keeps driving the released handle.
  func rebindMediaPlayerHandle() {
    guard let player = _mediaPlayer else { return }
    let replacementLease = player.nativeHandleLifetime.acquireNativeOwnerLease()
    let previousLease = nativePlayerBindingLease
    libvlc_media_list_player_set_media_player(pointer, player.pointer)
    nativePlayerBindingLease = replacementLease
    previousLease?.endAfterNativeOwnerRelease()
  }

  /// The media list to play.
  ///
  /// Clearing the list rebuilds this wrapper because libVLC has no nullable
  /// list setter. If a media player is attached, its current playback keeps
  /// running on the replacement wrapper's shared native handle.
  public var mediaList: MediaList? {
    get { _mediaList }
    set {
      _mediaList = newValue
      if let newValue {
        libvlc_media_list_player_set_media_list(pointer, newValue.pointer)
      } else {
        // The successor retains and adopts the same media-player handle. The
        // retiring wrapper must release without stopping that shared handle.
        rebuildNativePlayer(stopSharedPlayerBeforeDetaching: _mediaPlayer == nil)
      }
    }
  }

  /// The playback mode (default, loop, or repeat).
  public var playbackMode: PlaybackMode {
    get { _playbackMode }
    set {
      _playbackMode = newValue
      libvlc_media_list_player_set_playback_mode(pointer, newValue.cValue)
    }
  }

  /// Starts playing the media list from the beginning.
  public func play() {
    guard (try? prepareAttachedPlayerForPlayback()) == true else { return }
    guard
      attachedPlayerHandleIsCurrent,
      let reservation = reservePlaybackStart()
    else { return }
    let hasPlayableItem = _mediaList?.isEmpty == false
    let result = dispatchNativeTransport(.play, on: reservation.nativeListPlayer)
    settlePlaybackStart(
      reservation,
      accepted: result == 0 && hasPlayableItem
    )
  }

  /// Toggles between playing and paused. No-op in transient states
  /// (`.opening`, `.buffering`, `.stopping`, `.error`).
  ///
  /// Dispatches on the observed ``state`` rather than calling the raw
  /// `libvlc_media_list_player_pause` (which is itself a toggle). The
  /// raw toggle is unsafe mid-transition: interleaving a pause-toggle
  /// with the audio output's opening path corrupts
  /// `stream->timing.pause_date` and trips the upstream assertion
  /// `stream->timing.pause_date == VLC_TICK_INVALID` in
  /// `src/audio_output/dec.c:876`, killing the process. Mirror the
  /// guard in ``Player/togglePlayPause()``.
  public func togglePause() {
    if let player = _mediaPlayer, player.nativePlayerNeedsReplacementBeforePlayback {
      // The list's state deliberately hides a retired handle as idle. Use
      // the attached player's observed state until its stop has settled.
      switch player.state {
      case .idle, .stopped:
        play()
      case .playing, .paused, .opening, .buffering, .stopping, .error:
        break
      }
      return
    }
    guard attachedPlayerHandleIsCurrent else { return }
    switch state {
    case .playing:
      pause()
    case .paused:
      resume()
    case .idle, .stopped:
      play()
    case .opening, .buffering, .stopping, .error:
      break
    }
  }

  /// Pauses playback.
  public func pause() {
    guard attachedPlayerHandleIsCurrent else { return }
    if let mediaPlayer = _mediaPlayer {
      // The list-player "playing" flag can become true while the attached
      // media player is still opening or waiting for its first audio
      // timestamp. Sending the raw list-player pause in that window can be
      // lost (and bypasses Player's audio-output safety gate). Route through
      // the attached wrapper so its deferred-pause state machine retries the
      // command as soon as the shared native handle is pausable.
      mediaPlayer.pause()
    } else {
      libvlc_media_list_player_set_pause(pointer, 1)
    }
  }

  /// Resumes playback.
  public func resume() {
    if _mediaPlayer?.nativePlayerNeedsReplacementBeforePlayback == true {
      play()
      return
    }
    guard attachedPlayerHandleIsCurrent else { return }
    if let mediaPlayer = _mediaPlayer {
      mediaPlayer.resume()
    } else {
      libvlc_media_list_player_set_pause(pointer, 0)
    }
  }

  /// Whether the list player is currently playing.
  public var isPlaying: Bool {
    guard attachedPlayerHandleIsCurrent else { return false }
    return libvlc_media_list_player_is_playing(pointer)
  }

  /// Current playback state.
  public var state: PlayerState {
    guard attachedPlayerHandleIsCurrent else { return .idle }
    return PlayerState(from: libvlc_media_list_player_get_state(pointer))
  }

  /// Plays the item at the specified index.
  /// - Throws: ``VLCError/invalidState(_:)`` if no media list is attached,
  ///   ``VLCError/invalidInput(_:)`` if the index is out of range for the
  ///   attached list, or ``VLCError/operationFailed(_:)`` if libVLC rejects it.
  public func play(at requestedIndex: Int) throws(VLCError) {
    guard try prepareAttachedPlayerForPlayback() else {
      throw .invalidState("The attached Player is waiting for a fresh native handle")
    }
    let index = try checkedNonnegativeInt32(requestedIndex, parameter: "index")
    guard let count = _mediaList?.count else {
      throw .invalidState("mediaList must be set before playing by index")
    }
    if !(0..<count).contains(requestedIndex) {
      throw .invalidInput("index must be in 0..<\(count)")
    }
    guard let reservation = reservePlaybackStart() else {
      throw .invalidState("The attached Player changed before playback dispatch")
    }
    let result = dispatchNativeTransport(
      .playAt(index),
      on: reservation.nativeListPlayer
    )
    settlePlaybackStart(reservation, accepted: result == 0)
    guard result == 0 else {
      throw .operationFailed("Play item at index \(index)")
    }
  }

  /// Plays a specific media item from the list.
  /// - Throws: ``VLCError/invalidState(_:)`` if no media list is attached,
  ///   or ``VLCError/operationFailed(_:)`` if the item is not in the list.
  public func play(_ media: borrowing Media) throws(VLCError) {
    guard try prepareAttachedPlayerForPlayback() else {
      throw .invalidState("The attached Player is waiting for a fresh native handle")
    }
    guard _mediaList != nil else {
      throw .invalidState("mediaList must be set before playing an item")
    }
    guard let reservation = reservePlaybackStart() else {
      throw .invalidState("The attached Player changed before playback dispatch")
    }
    let result = dispatchNativeTransport(
      .playMedia(media.pointer),
      on: reservation.nativeListPlayer
    )
    settlePlaybackStart(reservation, accepted: result == 0)
    guard result == 0 else {
      throw .operationFailed("Play media item")
    }
  }

  /// Stops playback asynchronously.
  public func stop() {
    guard attachedPlayerHandleIsCurrent else { return }
    let nativeListPlayer = pointer
    if let mediaPlayer = _mediaPlayer {
      guard
        mediaPlayer.attachedMediaListPlayer === self,
        let reservation = mediaPlayer.reservePlaybackStop(
          establishesPlaybackBarrier: true
        ),
        pointer == nativeListPlayer,
        _mediaPlayer === mediaPlayer,
        mediaPlayer.attachedMediaListPlayer === self,
        mediaPlayer.preparePlaybackStopForExternalDispatch(reservation)
      else { return }
      _ = dispatchNativeTransport(.stop, on: nativeListPlayer)
    } else {
      _ = dispatchNativeTransport(.stop, on: nativeListPlayer)
    }
  }

  /// Advances to the next item in the list.
  /// - Throws: `VLCError.operationFailed` if there is no next item.
  public func next() throws(VLCError) {
    guard try prepareAttachedPlayerForPlayback() else {
      throw .invalidState("The attached Player is waiting for a fresh native handle")
    }
    guard let reservation = reservePlaybackStart() else {
      throw .invalidState("The attached Player changed before playback dispatch")
    }
    let result = dispatchNativeTransport(.next, on: reservation.nativeListPlayer)
    settlePlaybackStart(reservation, accepted: result == 0)
    guard result == 0 else {
      throw .operationFailed("Advance to next item")
    }
  }

  /// Goes back to the previous item in the list.
  /// - Throws: `VLCError.operationFailed` if there is no previous item.
  public func previous() throws(VLCError) {
    guard try prepareAttachedPlayerForPlayback() else {
      throw .invalidState("The attached Player is waiting for a fresh native handle")
    }
    guard let reservation = reservePlaybackStart() else {
      throw .invalidState("The attached Player changed before playback dispatch")
    }
    let result = dispatchNativeTransport(.previous, on: reservation.nativeListPlayer)
    settlePlaybackStart(reservation, accepted: result == 0)
    guard result == 0 else {
      throw .operationFailed("Go to previous item")
    }
  }

  /// Reserves callback/control ordering before a list command enters native
  /// code. libVLC is allowed to emit Playing or MediaChanged from inside the
  /// call, so clearing a previous Stop quarantine afterwards is too late.
  private func reservePlaybackStart() -> MediaListPlayerPlaybackStartReservation? {
    let nativeListPlayer = pointer
    guard let mediaPlayer = _mediaPlayer else {
      return MediaListPlayerPlaybackStartReservation(
        nativeListPlayer: nativeListPlayer,
        player: nil,
        nativePlayer: nil,
        nativeHandleGeneration: nil,
        mediaListOwnershipEpoch: nil,
        playbackControlRevision: nil,
        playbackStartAttempt: nil
      )
    }
    guard
      mediaPlayer.attachedMediaListPlayer === self,
      mediaPlayer.nativeHandleRepresentsCurrentMedia,
      !mediaPlayer.nativePlayerNeedsReplacementBeforePlayback
    else { return nil }
    let nativePlayer = mediaPlayer.pointer
    let nativeHandleGeneration = mediaPlayer.eventBridge.currentNativeHandleGeneration
    let playbackGeneration = mediaPlayer.eventBridge.currentPlaybackGeneration
    let ownershipEpoch = mediaPlayer.mediaListOwnershipEpoch
    let playbackControlRevision = mediaPlayer.playbackControlIntentRevision
    let attempt = mediaPlayer.eventBridge.beginPlaybackStartAttempt(
      playbackGeneration: playbackGeneration
    )
    guard
      let attempt,
      pointer == nativeListPlayer,
      _mediaPlayer === mediaPlayer,
      mediaPlayer.pointer == nativePlayer,
      mediaPlayer.attachedMediaListPlayer === self,
      mediaPlayer.mediaListOwnershipEpoch == ownershipEpoch,
      mediaPlayer.eventBridge.currentNativeHandleGeneration == nativeHandleGeneration,
      mediaPlayer.eventBridge.currentPlaybackGeneration == playbackGeneration,
      mediaPlayer.eventBridge.currentLifecycleControlEpoch == attempt.lifecycleControlEpoch,
      mediaPlayer.playbackControlIntentRevision == playbackControlRevision
    else {
      mediaPlayer.eventBridge.finishPlaybackStartAttempt(attempt, accepted: false)
      return nil
    }
    return MediaListPlayerPlaybackStartReservation(
      nativeListPlayer: nativeListPlayer,
      player: mediaPlayer,
      nativePlayer: nativePlayer,
      nativeHandleGeneration: nativeHandleGeneration,
      mediaListOwnershipEpoch: ownershipEpoch,
      playbackControlRevision: playbackControlRevision,
      playbackStartAttempt: attempt
    )
  }

  /// Settles both accepted and rejected native starts. Rejection restores the
  /// pre-existing Stop barrier; acceptance may legitimately have advanced to
  /// a successor playlist generation while the native call was in progress.
  private func settlePlaybackStart(
    _ reservation: MediaListPlayerPlaybackStartReservation,
    accepted: Bool
  ) {
    guard let mediaPlayer = reservation.player else { return }
    mediaPlayer.eventBridge.finishPlaybackStartAttempt(
      reservation.playbackStartAttempt,
      accepted: accepted
    )
    guard
      accepted,
      pointer == reservation.nativeListPlayer,
      _mediaPlayer === mediaPlayer,
      mediaPlayer.pointer == reservation.nativePlayer,
      mediaPlayer.attachedMediaListPlayer === self,
      mediaPlayer.mediaListOwnershipEpoch == reservation.mediaListOwnershipEpoch,
      mediaPlayer.eventBridge.currentNativeHandleGeneration
      == reservation.nativeHandleGeneration,
      mediaPlayer.playbackControlIntentRevision == reservation.playbackControlRevision
    else { return }
    publishAcceptedPlayIntent(on: mediaPlayer)
  }

  /// Records an accepted list play before reconciling the shared native
  /// handle. Prepublishing resume makes a stable native-idle response preserve
  /// the accepted command, while `issueResume` replaces an older deferred or
  /// in-flight pause when list playback is already starting.
  private func publishAcceptedPlayIntent(on mediaPlayer: Player) {
    mediaPlayer.nativePlayerHasStartedPlayback = true
    guard mediaPlayer.setPlaybackControlIntent(.resume) else { return }
    let acceptedControlRevision = mediaPlayer.playbackControlIntentRevision
    guard
      _mediaPlayer === mediaPlayer,
      mediaPlayer.attachedMediaListPlayer === self,
      mediaPlayer.playbackControlIntent == .resume,
      mediaPlayer.playbackControlIntentRevision == acceptedControlRevision,
      !mediaPlayer.eventBridge.hasExplicitStopBarrier(
        playbackGeneration: mediaPlayer.eventBridge.currentPlaybackGeneration
      )
    else { return }
    mediaPlayer.resume()
  }

  private func dispatchNativeTransport(
    _ command: MediaListPlayerNativeTransportCommand,
    on nativeListPlayer: OpaquePointer
  ) -> Int32 {
    #if DEBUG
    if let _nativeTransportDispatchOverrideForTesting {
      return _nativeTransportDispatchOverrideForTesting(command)
    }
    #endif
    switch command {
    case .play:
      libvlc_media_list_player_play(nativeListPlayer)
      return 0
    case .playAt(let index):
      return libvlc_media_list_player_play_item_at_index(nativeListPlayer, index)
    case .playMedia(let media):
      return libvlc_media_list_player_play_item(nativeListPlayer, media)
    case .stop:
      libvlc_media_list_player_stop_async(nativeListPlayer)
      return 0
    case .next:
      return libvlc_media_list_player_next(nativeListPlayer)
    case .previous:
      return libvlc_media_list_player_previous(nativeListPlayer)
    }
  }

  /// Relinquishes a player that another list player is about to adopt. Keep
  /// end synthesis suppressed across the atomic main-actor transfer, and do
  /// not stop the shared native player from the retiring wrapper.
  private func detachForOwnershipTransfer(_ player: Player) {
    guard _mediaPlayer === player else { return }
    _mediaPlayer = nil
    if player.attachedMediaListPlayer === self {
      player.transitionMediaListOwnership(to: nil)
    }
    rebuildNativePlayer(stopSharedPlayerBeforeDetaching: false)
  }

  private func rebuildNativePlayer(stopSharedPlayerBeforeDetaching: Bool) {
    guard let replacement = libvlc_media_list_player_new(instance.pointer) else {
      preconditionFailure("Failed to rebuild libvlc media list player. Is the libvlc.xcframework linked correctly?")
    }

    libvlc_media_list_player_set_playback_mode(replacement, _playbackMode.cValue)
    var replacementLease: NativePlayerHandleLease?
    if let mediaPlayer = _mediaPlayer {
      let lease = mediaPlayer.nativeHandleLifetime.acquireNativeOwnerLease()
      libvlc_media_list_player_set_media_player(replacement, mediaPlayer.pointer)
      replacementLease = lease
    }
    if let mediaList = _mediaList {
      libvlc_media_list_player_set_media_list(replacement, mediaList.pointer)
    }

    let previous = pointer
    let previousLease = nativePlayerBindingLease
    if let previousLease {
      // `release` is intentionally off-main, but merely queueing it leaves the
      // retiring list player able to receive an end callback and advance the
      // shared player after this method returns. Rebind it synchronously to an
      // independent neutral player: pinned libVLC removes the old observer and
      // releases the old player inside this call. Subsequent stop/release work
      // can then affect only the neutral handle.
      if stopSharedPlayerBeforeDetaching {
        libvlc_media_list_player_stop_async(previous)
      }
      guard let neutralPlayer = libvlc_media_player_new(instance.pointer) else {
        preconditionFailure("Failed to create a neutral libVLC media player during list-player rebuild.")
      }
      libvlc_media_list_player_set_media_player(previous, neutralPlayer)
      previousLease.endAfterNativeOwnerRelease()
      libvlc_media_player_release(neutralPlayer)
    }
    pointer = replacement
    nativePlayerBindingLease = replacementLease
    nonisolated(unsafe) let oldPointer = previous
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_list_player_stop_async(oldPointer)
      libvlc_media_list_player_release(oldPointer)
    }
  }

  /// A drawable-hosted stop retires the handle before the next transport.
  /// Preparing the replacement also rebinds this list player's native owner.
  /// Observation during preparation can install a newer command or owner;
  /// that takeover must prevent this older transport from being dispatched.
  private func prepareAttachedPlayerForPlayback() throws(VLCError) -> Bool {
    guard let player = _mediaPlayer else { return true }
    guard
      !player.isShutdown,
      player.attachedMediaListPlayer === self,
      player.eventBridge.currentPlaybackGeneration == player.sessionGeneration
    else { return false }
    guard player.nativePlayerNeedsReplacementBeforePlayback else {
      return attachedPlayerHandleIsCurrent
    }
    let listPlayer = pointer
    let list = _mediaList
    let ownership = player.mediaListOwnershipEpoch
    let generation = player.sessionGeneration
    let control = player.playbackControlIntentRevision
    try player.prepareDrawableForPlayback()
    return pointer == listPlayer
      && _mediaList === list
      && _mediaPlayer === player
      && player.attachedMediaListPlayer === self
      && player.mediaListOwnershipEpoch == ownership
      && player.sessionGeneration == generation
      && player.playbackControlIntentRevision == control
      && !player.isShutdown
      && attachedPlayerHandleIsCurrent
  }

  private var attachedPlayerHandleIsCurrent: Bool {
    _mediaPlayer?.nativeHandleRepresentsCurrentMedia != false
      && _mediaPlayer?.nativePlayerNeedsReplacementBeforePlayback != true
  }
}

extension Player {
  func transitionMediaListOwnership(to owner: MediaListPlayer?) {
    guard attachedMediaListPlayer !== owner else { return }
    precondition(mediaListOwnershipEpoch < UInt64.max, "Media-list ownership epoch exhausted")
    mediaListOwnershipEpoch += 1
    attachedMediaListPlayer = owner
  }
}
