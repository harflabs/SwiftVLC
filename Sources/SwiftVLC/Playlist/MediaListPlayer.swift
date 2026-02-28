import CLibVLC

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
/// let player = try Player()
/// let listPlayer = try MediaListPlayer(player: player)
/// listPlayer.mediaList = list
/// listPlayer.play()
/// ```
public final class MediaListPlayer: Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_list_player_t*
    private nonisolated(unsafe) var _mediaPlayer: Player?
    private nonisolated(unsafe) var _mediaList: MediaList?
    private nonisolated(unsafe) var _playbackMode: PlaybackMode = .default

    /// Creates a new media list player.
    /// - Parameter instance: The VLC instance to use.
    /// - Throws: `VLCError.instanceCreationFailed` if allocation fails.
    public init(instance: VLCInstance = .shared) throws(VLCError) {
        guard let p = libvlc_media_list_player_new(instance.pointer) else {
            throw .instanceCreationFailed
        }
        pointer = p
    }

    deinit {
        libvlc_media_list_player_release(pointer)
    }

    /// The ``Player`` used for actual playback.
    public var mediaPlayer: Player? {
        get { _mediaPlayer }
        set {
            _mediaPlayer = newValue
            if let newValue {
                libvlc_media_list_player_set_media_player(pointer, newValue.pointer)
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

    /// Toggles pause/resume.
    public func togglePause() {
        libvlc_media_list_player_pause(pointer)
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
    public func play(at index: Int) throws(VLCError) {
        guard libvlc_media_list_player_play_item_at_index(pointer, Int32(index)) == 0 else {
            throw .operationFailed
        }
    }

    /// Plays a specific media item from the list.
    public func play(_ media: Media) throws(VLCError) {
        guard libvlc_media_list_player_play_item(pointer, media.pointer) == 0 else {
            throw .operationFailed
        }
    }

    /// Stops playback asynchronously.
    public func stop() {
        libvlc_media_list_player_stop_async(pointer)
    }

    /// Advances to the next item in the list.
    public func next() throws(VLCError) {
        guard libvlc_media_list_player_next(pointer) == 0 else {
            throw .operationFailed
        }
    }

    /// Goes back to the previous item in the list.
    public func previous() throws(VLCError) {
        guard libvlc_media_list_player_previous(pointer) == 0 else {
            throw .operationFailed
        }
    }
}
