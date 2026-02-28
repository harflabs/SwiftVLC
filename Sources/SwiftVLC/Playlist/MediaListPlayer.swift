import CLibVLC

/// A playlist player that plays media from a ``MediaList``.
///
/// Wraps `libvlc_media_list_player_t` and provides sequential, looping,
/// or repeating playback of a list of media items.
///
/// ```swift
/// let list = MediaList()
/// list.append(media1)
/// list.append(media2)
///
/// let player = try Player()
/// let listPlayer = try MediaListPlayer(player: player)
/// listPlayer.setMediaList(list)
/// listPlayer.play()
/// ```
public final class MediaListPlayer: Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_list_player_t*

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

    /// Associates a ``Player`` with this list player.
    ///
    /// The list player will use the given player for actual playback.
    public func setMediaPlayer(_ player: Player) {
        libvlc_media_list_player_set_media_player(pointer, player.pointer)
    }

    /// Sets the media list to play.
    public func setMediaList(_ list: MediaList) {
        libvlc_media_list_player_set_media_list(pointer, list.pointer)
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
    /// - Returns: `true` if the item was found and playback started.
    @discardableResult
    public func play(at index: Int) -> Bool {
        libvlc_media_list_player_play_item_at_index(pointer, Int32(index)) == 0
    }

    /// Plays a specific media item from the list.
    /// - Returns: `true` if the item was found in the list.
    @discardableResult
    public func play(_ media: Media) -> Bool {
        libvlc_media_list_player_play_item(pointer, media.pointer) == 0
    }

    /// Stops playback asynchronously.
    public func stop() {
        libvlc_media_list_player_stop_async(pointer)
    }

    /// Advances to the next item in the list.
    /// - Returns: `true` if there is a next item.
    @discardableResult
    public func next() -> Bool {
        libvlc_media_list_player_next(pointer) == 0
    }

    /// Goes back to the previous item in the list.
    /// - Returns: `true` if there is a previous item.
    @discardableResult
    public func previous() -> Bool {
        libvlc_media_list_player_previous(pointer) == 0
    }

    /// Sets the playback mode (default, loop, or repeat).
    public func setPlaybackMode(_ mode: PlaybackMode) {
        libvlc_media_list_player_set_playback_mode(pointer, mode.cValue)
    }
}
