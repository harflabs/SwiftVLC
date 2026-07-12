import CLibVLC
import Dispatch

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
        newValue.attachedMediaListPlayer = self
      } else {
        if let previous {
          detachForEndSynthesis(previous, nativeStopWillFollow: true)
        }
        _mediaPlayer = nil
        rebuildNativePlayer(stopSharedPlayerBeforeDetaching: true)
      }
    }
  }

  /// Detach-time end-synthesis bookkeeping for a previously attached
  /// player. A nil detach or final list-player teardown stops the still-bound
  /// handle later, so it records that stop as library-initiated before lifting
  /// suppression. Replacing or transferring an attachment does not stop the
  /// old player and must not leave a stale stop mark that can swallow its next
  /// genuine end. Suppression is lifted unless another list player has since
  /// taken over the attachment.
  private func detachForEndSynthesis(
    _ previous: Player,
    nativeStopWillFollow: Bool = true
  ) {
    if nativeStopWillFollow {
      switch previous.nativePlaybackState {
      case .idle, .stopped, .error:
        break
      default:
        previous.endCoordinator.markLibraryStop()
      }
    }
    let owner = previous.attachedMediaListPlayer
    guard owner === self || owner == nil else { return }
    previous.endCoordinator.setSuppressed(false)
    previous.attachedMediaListPlayer = nil
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
    libvlc_media_list_player_play(pointer)
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
    libvlc_media_list_player_set_pause(pointer, 1)
  }

  /// Resumes playback.
  public func resume() {
    libvlc_media_list_player_set_pause(pointer, 0)
  }

  /// Whether the list player is currently playing.
  public var isPlaying: Bool {
    libvlc_media_list_player_is_playing(pointer)
  }

  /// Current playback state.
  public var state: PlayerState {
    PlayerState(from: libvlc_media_list_player_get_state(pointer))
  }

  /// Plays the item at the specified index.
  /// - Throws: ``VLCError/invalidState(_:)`` if no media list is attached,
  ///   ``VLCError/invalidInput(_:)`` if the index is out of range for the
  ///   attached list, or ``VLCError/operationFailed(_:)`` if libVLC rejects it.
  public func play(at requestedIndex: Int) throws(VLCError) {
    let index = try checkedNonnegativeInt32(requestedIndex, parameter: "index")
    guard let count = _mediaList?.count else {
      throw .invalidState("mediaList must be set before playing by index")
    }
    if !(0..<count).contains(requestedIndex) {
      throw .invalidInput("index must be in 0..<\(count)")
    }
    guard libvlc_media_list_player_play_item_at_index(pointer, index) == 0 else {
      throw .operationFailed("Play item at index \(index)")
    }
  }

  /// Plays a specific media item from the list.
  /// - Throws: ``VLCError/invalidState(_:)`` if no media list is attached,
  ///   or ``VLCError/operationFailed(_:)`` if the item is not in the list.
  public func play(_ media: borrowing Media) throws(VLCError) {
    guard _mediaList != nil else {
      throw .invalidState("mediaList must be set before playing an item")
    }
    guard libvlc_media_list_player_play_item(pointer, media.pointer) == 0 else {
      throw .operationFailed("Play media item")
    }
  }

  /// Stops playback asynchronously.
  public func stop() {
    libvlc_media_list_player_stop_async(pointer)
  }

  /// Advances to the next item in the list.
  /// - Throws: `VLCError.operationFailed` if there is no next item.
  public func next() throws(VLCError) {
    guard libvlc_media_list_player_next(pointer) == 0 else {
      throw .operationFailed("Advance to next item")
    }
  }

  /// Goes back to the previous item in the list.
  /// - Throws: `VLCError.operationFailed` if there is no previous item.
  public func previous() throws(VLCError) {
    guard libvlc_media_list_player_previous(pointer) == 0 else {
      throw .operationFailed("Go to previous item")
    }
  }

  /// Relinquishes a player that another list player is about to adopt. Keep
  /// end synthesis suppressed across the atomic main-actor transfer, and do
  /// not stop the shared native player from the retiring wrapper.
  private func detachForOwnershipTransfer(_ player: Player) {
    guard _mediaPlayer === player else { return }
    _mediaPlayer = nil
    if player.attachedMediaListPlayer === self {
      player.attachedMediaListPlayer = nil
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
}
