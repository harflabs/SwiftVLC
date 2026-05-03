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
    // Release off the main actor. `stop_async` and `release` can block
    // waiting for VLC's internal threads, stalling all async work.
    nonisolated(unsafe) let p = pointer
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_list_player_stop_async(p)
      libvlc_media_list_player_release(p)
    }
  }

  /// The ``Player`` used for actual playback.
  public var mediaPlayer: Player? {
    get { _mediaPlayer }
    set {
      _mediaPlayer = newValue
      if let newValue {
        libvlc_media_list_player_set_media_player(pointer, newValue.pointer)
      } else {
        rebuildNativePlayer()
      }
    }
  }

  /// The media list to play.
  public var mediaList: MediaList? {
    get { _mediaList }
    set {
      _mediaList = newValue
      if let newValue {
        libvlc_media_list_player_set_media_list(pointer, newValue.pointer)
      } else {
        rebuildNativePlayer()
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
  /// naked toggle is unsafe mid-transition: interleaving a pause-toggle
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
  /// - Throws: `VLCError.operationFailed` if the index is out of range.
  public func play(at index: Int) throws(VLCError) {
    guard libvlc_media_list_player_play_item_at_index(pointer, Int32(index)) == 0 else {
      throw .operationFailed("Play item at index \(index)")
    }
  }

  /// Plays a specific media item from the list.
  /// - Throws: `VLCError.operationFailed` if the item is not in the list.
  public func play(_ media: borrowing Media) throws(VLCError) {
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

  private func rebuildNativePlayer() {
    guard let replacement = libvlc_media_list_player_new(instance.pointer) else {
      preconditionFailure("Failed to rebuild libvlc media list player. Is the libvlc.xcframework linked correctly?")
    }

    libvlc_media_list_player_set_playback_mode(replacement, _playbackMode.cValue)
    if let mediaPlayer = _mediaPlayer {
      libvlc_media_list_player_set_media_player(replacement, mediaPlayer.pointer)
    }
    if let mediaList = _mediaList {
      libvlc_media_list_player_set_media_list(replacement, mediaList.pointer)
    }

    let previous = pointer
    pointer = replacement
    nonisolated(unsafe) let oldPointer = previous
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_list_player_stop_async(oldPointer)
      libvlc_media_list_player_release(oldPointer)
    }
  }
}
