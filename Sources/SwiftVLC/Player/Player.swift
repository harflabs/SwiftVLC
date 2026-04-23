import CLibVLC
import Foundation
import Observation

/// An observable media player.
///
/// `Player` wraps `libvlc_media_player_t` with `@Observable` and
/// `@MainActor`, so SwiftUI views update in response to libVLC state
/// without a publisher adapter.
///
/// ```swift
/// struct PlayerView: View {
///     @State private var player = Player()
///
///     var body: some View {
///         VideoView(player)
///         Text(player.state.description)
///         Button(player.isPlaying ? "Pause" : "Play") {
///             player.isPlaying ? player.pause() : try? player.play()
///         }
///     }
/// }
/// ```
///
/// The observable properties (`state`, `currentTime`, `duration`,
/// and the track lists) are fed by an internal event consumer. No
/// delegate protocols, Combine publishers, or manual bridging are
/// involved.
@Observable
@MainActor
public final class Player {
  // MARK: - Observable State

  /// Current playback state.
  public private(set) var state: PlayerState = .idle

  /// Current playback time.
  public private(set) var currentTime: Duration = .zero

  /// Total media duration (nil until known).
  public private(set) var duration: Duration?

  /// Whether the current media is seekable.
  public private(set) var isSeekable: Bool = false

  /// Whether the current media can be paused.
  public private(set) var isPausable: Bool = false

  /// Buffer fill, normalized to `0.0...1.0`.
  ///
  /// Updated continuously while playback is active, including while
  /// ``state`` is `.paused` or `.playing`. Read this for a progress
  /// bar; the `state` enum only carries lifecycle information.
  public private(set) var bufferFill: Float = 0

  /// The currently loaded media.
  public private(set) var currentMedia: Media?

  /// Available audio tracks.
  public private(set) var audioTracks: [Track] = []

  /// Available video tracks.
  public private(set) var videoTracks: [Track] = []

  /// Available subtitle tracks.
  public private(set) var subtitleTracks: [Track] = []

  // MARK: - Bindable Properties

  /// Fractional playback position (0.0...1.0). Setting this seeks.
  public var position: Double {
    get {
      access(keyPath: \.position)
      return _position
    }
    set {
      withMutation(keyPath: \.position) {
        _position = newValue
        libvlc_media_player_set_position(pointer, newValue, /* fast */ false)
      }
      // libVLC doesn't reliably emit `MediaPlayerTimeChanged` after a
      // `set_position`, especially while paused, so `currentTime` appears
      // stuck at its pre-seek value. Update optimistically when duration
      // is known; the subsequent timeChanged event refines the estimate
      // with libVLC's post-seek frame timestamp.
      if let dur = duration {
        currentTime = dur * newValue
      }
    }
  }

  /// Volume level, normalized. `0.0` is silent, `1.0` is 100%. Values
  /// above `1.0` amplify, up to `1.25` (125%).
  ///
  /// Backed by a shadow `_volume` instead of a live libVLC read.
  /// Before the audio output is initialized `libvlc_audio_get_volume`
  /// returns a negative sentinel (`-100` on libVLC 4.0), which would
  /// surface in the UI as `-100%` even while the user is hearing audio
  /// at the default level. The shadow starts at `1.0` and is refreshed
  /// from the native player on each state transition, once libVLC's
  /// audio output can be trusted.
  public var volume: Float {
    get {
      access(keyPath: \.volume)
      return _volume
    }
    set {
      withMutation(keyPath: \.volume) {
        _volume = max(0, newValue)
        libvlc_audio_set_volume(pointer, Int32(_volume * 100))
      }
    }
  }

  /// Whether audio is muted. Shadowed by `_isMuted` for the same
  /// reason as `volume`: `libvlc_audio_get_mute` returns `-1` when the
  /// mute status is undefined, which a naive `Int32 > 0` check would
  /// silently map to `false` and hide a real mute toggle.
  public var isMuted: Bool {
    get {
      access(keyPath: \.isMuted)
      return _isMuted
    }
    set {
      withMutation(keyPath: \.isMuted) {
        _isMuted = newValue
        libvlc_audio_set_mute(pointer, newValue ? 1 : 0)
      }
    }
  }

  /// Playback rate. `1.0` is normal speed, `0.5` is half, `2.0` is
  /// double. Any positive rate is accepted; the practical range is
  /// `0.25` to `4.0` before audio/video sync degrades.
  ///
  /// This setter discards libVLC's rejection signal so a slider binding
  /// never throws. Call ``setRate(_:)`` instead when the UI needs to
  /// react to rejection. Live HLS and RTSP streams often reject
  /// non-`1.0` rates, and `setRate(_:)` throws
  /// ``VLCError/operationFailed(_:)`` in that case.
  public var rate: Float {
    get {
      access(keyPath: \.rate)
      return libvlc_media_player_get_rate(pointer)
    }
    set {
      try? setRate(newValue)
    }
  }

  /// Sets the playback rate, throwing if libVLC rejects the value.
  ///
  /// Typical rejections:
  /// - Live streams (HLS, RTSP) that only support `1.0` playback.
  /// - No media loaded yet. libVLC ignores the call until playback
  ///   starts.
  /// - Format-specific decoder limitations.
  ///
  /// - Parameter newRate: Target rate. `1.0` is normal speed.
  /// - Throws: ``VLCError/operationFailed(_:)`` if libVLC rejects the rate.
  public func setRate(_ newRate: Float) throws(VLCError) {
    let rc = withMutation(keyPath: \.rate) {
      libvlc_media_player_set_rate(pointer, newRate)
    }
    if rc != 0 {
      throw .operationFailed("Set rate to \(newRate)")
    }
  }

  /// The currently selected audio track, or `nil` if none is selected.
  ///
  /// Setting to `nil` deselects the active audio track. Output stays
  /// silent until another track is chosen.
  public var selectedAudioTrack: Track? {
    get {
      access(keyPath: \.selectedAudioTrack)
      return audioTracks.first(where: \.isSelected)
    }
    set {
      withMutation(keyPath: \.selectedAudioTrack) {
        selectTrack(newValue, type: .audio)
      }
    }
  }

  /// The currently selected subtitle track, or `nil` if subtitles are off.
  ///
  /// Setting to `nil` deselects the active subtitle track.
  public var selectedSubtitleTrack: Track? {
    get {
      access(keyPath: \.selectedSubtitleTrack)
      return subtitleTracks.first(where: \.isSelected)
    }
    set {
      withMutation(keyPath: \.selectedSubtitleTrack) {
        selectTrack(newValue, type: .subtitle)
      }
    }
  }

  /// Video aspect ratio override.
  public var aspectRatio: AspectRatio = .default {
    didSet { applyAspectRatio() }
  }

  /// Audio delay relative to video. Positive values delay audio (make it play later).
  public var audioDelay: Duration {
    get {
      access(keyPath: \.audioDelay)
      return .microseconds(libvlc_audio_get_delay(pointer))
    }
    set {
      _ = withMutation(keyPath: \.audioDelay) {
        libvlc_audio_set_delay(pointer, newValue.microseconds)
      }
    }
  }

  /// Subtitle delay relative to video. Positive values delay subtitles (make them appear later).
  public var subtitleDelay: Duration {
    get {
      access(keyPath: \.subtitleDelay)
      return .microseconds(libvlc_video_get_spu_delay(pointer))
    }
    set {
      _ = withMutation(keyPath: \.subtitleDelay) {
        libvlc_video_set_spu_delay(pointer, newValue.microseconds)
      }
    }
  }

  /// Subtitle text scale factor (1.0 = 100%, 0.5 = 50%, 2.0 = 200%).
  /// Clamped to [0.1, 5.0] by libVLC.
  public var subtitleTextScale: Float {
    get {
      access(keyPath: \.subtitleTextScale)
      return libvlc_video_get_spu_text_scale(pointer)
    }
    set {
      withMutation(keyPath: \.subtitleTextScale) {
        libvlc_video_set_spu_text_scale(pointer, newValue)
      }
    }
  }

  /// The player's role, used to hint the system about audio behavior.
  public var role: PlayerRole {
    get {
      access(keyPath: \.role)
      return PlayerRole(from: libvlc_media_player_get_role(pointer))
    }
    set {
      _ = withMutation(keyPath: \.role) {
        libvlc_media_player_set_role(pointer, newValue.cValue)
      }
    }
  }

  // MARK: - Convenience

  /// Whether the player is currently playing.
  public var isPlaying: Bool {
    access(keyPath: \.isPlaying)
    return state == .playing
  }

  /// Whether playback is active (playing or buffering during playback).
  public var isActive: Bool {
    access(keyPath: \.isActive)
    return switch state {
    case .playing, .opening, .buffering:
      true
    default:
      false
    }
  }

  /// Convenience access to current media statistics.
  public var statistics: MediaStatistics? {
    currentMedia?.statistics()
  }

  // MARK: - Event Stream

  /// Raw event stream for custom processing.
  /// Most consumers should use `@Observable` properties instead.
  public nonisolated var events: AsyncStream<PlayerEvent> {
    eventBridge.makeStream()
  }

  // MARK: - Internal

  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_player_t*
  private let eventBridge: EventBridge
  private var eventTask: Task<Void, Never>?
  private var _position: Double = 0
  private var _equalizer: Equalizer?
  private var _volume: Float = 1.0
  private var _isMuted: Bool = false
  // Shadow of the string last passed to `Marquee.setText`. libVLC's text
  // renderer keys its glyph-bitmap cache on the text string, so a style-
  // only write (color/opacity/fontSize) hits the cached entry and draws
  // with the old style. The `Marquee` setters briefly write a different
  // text to bust the cache, then restore this value.
  var _marqueeText: String = ""
  let instance: VLCInstance

  // MARK: - Lifecycle

  /// Creates a new player.
  /// - Parameter instance: The VLC instance to use.
  public init(instance: VLCInstance = .shared) {
    guard let p = libvlc_media_player_new(instance.pointer) else {
      preconditionFailure("Failed to create libvlc media player. Is the libvlc.xcframework linked correctly?")
    }
    pointer = p
    self.instance = instance
    eventBridge = EventBridge(
      eventManager: libvlc_media_player_event_manager(p)!
    )
    startEventConsumer()
  }

  isolated deinit {
    eventTask?.cancel()
    // Move every VLC cleanup call off the main actor so deinit never
    // blocks the UI thread. `libvlc_event_detach` waits for an in-flight
    // C callback to finish, and `libvlc_media_player_release` can block
    // on internal threads; both can stall the main actor for seconds
    // under load.
    //
    // Safety: `bridge` keeps the EventBridge (and its ContinuationStore)
    // alive until cleanup completes. The C player pointer is a plain
    // value. invalidate() MUST run before release() so the event
    // manager is still valid when detaching callbacks.
    let bridge = eventBridge
    nonisolated(unsafe) let p = pointer
    DispatchQueue.global(qos: .utility).async {
      bridge.invalidate()
      libvlc_media_player_stop_async(p)
      libvlc_media_player_release(p)
    }
  }

  // MARK: - Media Loading

  /// Loads media into the player, replacing whatever was previously loaded.
  ///
  /// `media` is declared `sending`, so callers can construct a ``Media``
  /// on any actor or task and hand it off to this main-actor method
  /// without a copy. The compiler enforces the transfer: the caller
  /// cannot retain the original reference after the call.
  public func load(_ media: sending Media) {
    currentMedia = media
    resetMediaDerivedState()
    libvlc_media_player_set_media(pointer, media.pointer)
    // No eager `refreshTracks()` here. The track list isn't populated
    // until libVLC emits `ESAdded` events after the demuxer opens, so
    // the `.tracksChanged` / `.mediaChanged` handlers refresh from a
    // single source of truth.
    notifyMediaDependentObservables()
  }

  // MARK: - Playback Control

  /// Loads media and starts playback in one step.
  /// - Throws: `VLCError.playbackFailed` if playback cannot start.
  public func play(_ media: sending Media) throws(VLCError) {
    load(media)
    try play()
  }

  /// Creates media from a URL and starts playback.
  /// - Throws: `VLCError.mediaCreationFailed` or `VLCError.playbackFailed`.
  public func play(url: URL) throws(VLCError) {
    try play(Media(url: url))
  }

  /// Starts playback.
  /// - Throws: `VLCError.playbackFailed` if playback cannot start.
  public func play() throws(VLCError) {
    if libvlc_media_player_play(pointer) == -1 {
      let reason = libvlc_errmsg().map { String(cString: $0) } ?? "unknown"
      throw .playbackFailed(reason: reason)
    }
  }

  /// Pauses playback.
  public func pause() {
    libvlc_media_player_set_pause(pointer, 1)
  }

  /// Resumes playback from pause.
  public func resume() {
    libvlc_media_player_set_pause(pointer, 0)
  }

  /// Toggles between playing and paused, or starts playback from an
  /// idle or stopped state. No-op in transient states (`.opening`,
  /// `.buffering`, `.stopping`, `.error`).
  ///
  /// Dispatches on the observed ``state`` rather than calling
  /// `libvlc_media_player_pause` (which is itself a toggle). The naked
  /// toggle is unsafe mid-transition: interleaving a pause-toggle with
  /// the audio output's opening path corrupts
  /// `stream->timing.pause_date` and trips the upstream assertion
  /// `stream->timing.pause_date == VLC_TICK_INVALID` in
  /// `src/audio_output/dec.c:876`, killing the process. The usual repro
  /// is a user tapping Play/Pause immediately after a
  /// `.task { try? player.play(url:) }` begins.
  public func togglePlayPause() {
    switch state {
    case .playing:
      pause()
    case .paused:
      resume()
    case .idle, .stopped:
      try? play()
    case .opening, .buffering, .stopping, .error:
      // Transient state. libVLC isn't ready to accept a pause-toggle
      // safely; ignore the input rather than corrupting its internal
      // audio-output state.
      break
    }
  }

  /// Stops playback asynchronously.
  public func stop() {
    libvlc_media_player_stop_async(pointer)
  }

  /// Seeks to an absolute time in the current media.
  ///
  /// No-op when the media is not seekable; observe ``isSeekable``
  /// before exposing scrub controls. The seek is asynchronous. Watch
  /// ``currentTime`` or the ``PlayerEvent/timeChanged(_:)`` event for
  /// completion.
  public func seek(to time: Duration) {
    libvlc_media_player_set_time(pointer, time.milliseconds, /* fast */ false)
    // Same optimistic update as the `position` setter: libVLC doesn't
    // always emit `MediaPlayerTimeChanged` after a seek (especially
    // while paused), so the published `currentTime` would appear stuck.
    // The subsequent timeChanged event refines this with libVLC's
    // post-seek frame timestamp.
    currentTime = time
  }

  /// Seeks by a relative offset from the current position.
  ///
  /// Negative offsets rewind, positive offsets fast-forward. Has no effect
  /// if the media is not seekable.
  public func seek(by offset: Duration) {
    libvlc_media_player_jump_time(pointer, offset.milliseconds)
    // Optimistic `currentTime` update for the same reason as `seek(to:)`.
    // Clamp to [0, duration] so the published value can never go
    // negative or past the end while libVLC catches up.
    var target = currentTime + offset
    if target < .zero {
      target = .zero
    } else if let dur = duration, target > dur {
      target = dur
    }
    currentTime = target
  }

  /// Pauses playback and advances one video frame.
  ///
  /// Requires the current media to be pausable (see ``isPausable``).
  /// Calling repeatedly yields frame-by-frame stepping.
  public func nextFrame() {
    libvlc_media_player_next_frame(pointer)
    // libVLC doesn't emit `MediaPlayerTimeChanged` after a next-frame
    // step while paused: the decoder advances one frame but the event
    // thread stays quiescent. Read the authoritative time directly so
    // `currentTime` reflects the step.
    let ms = libvlc_media_player_get_time(pointer)
    if ms >= 0 {
      currentTime = .milliseconds(ms)
    }
  }

  // MARK: - External Tracks

  /// Adds an external subtitle or audio file to the player.
  ///
  /// - Parameters:
  ///   - url: URL of the external track file (must use a valid scheme like `file://`).
  ///   - type: Whether this is a subtitle or audio track.
  ///   - select: If `true`, the track is selected immediately when loaded.
  /// - Throws: `VLCError.operationFailed` if the track cannot be added.
  public func addExternalTrack(from url: URL, type: MediaSlaveType, select: Bool = true) throws(VLCError) {
    let uri = url.absoluteString
    guard libvlc_media_player_add_slave(pointer, type.cValue, uri, select) == 0 else {
      throw .operationFailed("Add external \(type) track")
    }
  }

  // MARK: - Snapshot

  /// Takes a snapshot of the current video frame and writes it to disk as PNG.
  ///
  /// Pass `0` for `width` or `height` to derive that dimension from the
  /// other while preserving the source aspect ratio. Passing `0` for both
  /// writes the frame at its native resolution.
  ///
  /// - Parameters:
  ///   - path: Destination file path. The file is always PNG regardless of
  ///     the extension you provide.
  ///   - width: Desired width in pixels, or `0` to derive from `height`
  ///     and the aspect ratio.
  ///   - height: Desired height in pixels, or `0` to derive from `width`
  ///     and the aspect ratio.
  /// - Throws: ``VLCError/operationFailed(_:)`` if no frame is available
  ///   (e.g. audio-only media) or the file cannot be written.
  public func takeSnapshot(to path: String, width: Int = 0, height: Int = 0) throws(VLCError) {
    guard libvlc_video_take_snapshot(pointer, 0, path, UInt32(width), UInt32(height)) == 0 else {
      throw .operationFailed("Take snapshot")
    }
  }

  // MARK: - Recording

  /// Starts recording the current stream to the specified directory.
  ///
  /// Listen to ``PlayerEvent/recordingChanged(isRecording:filePath:)`` for state updates.
  /// - Parameter directory: Path to save recording (`nil` for default).
  public func startRecording(to directory: String? = nil) {
    libvlc_media_player_record(pointer, true, directory)
  }

  /// Stops recording the current stream.
  public func stopRecording() {
    libvlc_media_player_record(pointer, false, nil)
  }

  // MARK: - Navigation (DVD menus)

  /// Navigates through DVD/Blu-ray menus.
  public func navigate(_ action: NavigationAction) {
    libvlc_media_player_navigate(pointer, action.cValue)
  }

  // MARK: - Chapters & Titles

  /// Number of chapters in the current title.
  public var chapterCount: Int {
    Int(libvlc_media_player_get_chapter_count(pointer))
  }

  /// Current chapter index, zero-based (get/set).
  public var currentChapter: Int {
    get {
      access(keyPath: \.currentChapter)
      return Int(libvlc_media_player_get_chapter(pointer))
    }
    set {
      withMutation(keyPath: \.currentChapter) {
        libvlc_media_player_set_chapter(pointer, Int32(newValue))
      }
    }
  }

  /// Navigates to the next chapter.
  public func nextChapter() {
    libvlc_media_player_next_chapter(pointer)
  }

  /// Navigates to the previous chapter.
  public func previousChapter() {
    libvlc_media_player_previous_chapter(pointer)
  }

  /// Number of titles.
  public var titleCount: Int {
    Int(libvlc_media_player_get_title_count(pointer))
  }

  /// Current title index, zero-based (get/set).
  public var currentTitle: Int {
    get {
      access(keyPath: \.currentTitle)
      return Int(libvlc_media_player_get_title(pointer))
    }
    set {
      withMutation(keyPath: \.currentTitle) {
        libvlc_media_player_set_title(pointer, Int32(newValue))
      }
    }
  }

  /// Full title descriptions for the current media.
  public var titles: [Title] {
    var cTitles: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_title_description_t>?>?
    let count = libvlc_media_player_get_full_title_descriptions(pointer, &cTitles)
    guard count > 0, let cTitles else { return [] }
    defer { libvlc_title_descriptions_release(cTitles, UInt32(count)) }

    return (0..<Int(count)).compactMap { i -> Title? in
      guard let desc = cTitles[i]?.pointee else { return nil }
      return Title(
        index: i,
        duration: .milliseconds(desc.i_duration),
        name: desc.psz_name.map { String(cString: $0) },
        isMenu: desc.i_flags & UInt32(libvlc_title_menu) != 0,
        isInteractive: desc.i_flags & UInt32(libvlc_title_interactive) != 0
      )
    }
  }

  /// Full chapter descriptions for a title.
  /// - Parameter titleIndex: Zero-based title index, or `-1` for the current title.
  public func chapters(forTitle titleIndex: Int = -1) -> [Chapter] {
    var cChapters: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_chapter_description_t>?>?
    let count = libvlc_media_player_get_full_chapter_descriptions(
      pointer, Int32(titleIndex), &cChapters
    )
    guard count > 0, let cChapters else { return [] }
    defer { libvlc_chapter_descriptions_release(cChapters, UInt32(count)) }

    return (0..<Int(count)).compactMap { i -> Chapter? in
      guard let desc = cChapters[i]?.pointee else { return nil }
      return Chapter(
        index: i,
        timeOffset: .milliseconds(desc.i_time_offset),
        duration: .milliseconds(desc.i_duration),
        name: desc.psz_name.map { String(cString: $0) }
      )
    }
  }

  // MARK: - A-B Loop

  /// Sets an A-B loop using absolute times.
  /// - Throws: `VLCError.operationFailed` if the loop cannot be set.
  public func setABLoop(a: Duration, b: Duration) throws(VLCError) {
    guard libvlc_media_player_set_abloop_time(pointer, a.milliseconds, b.milliseconds) == 0 else {
      throw .operationFailed("Set A-B loop by time")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Sets an A-B loop using fractional positions (0.0...1.0).
  /// - Throws: `VLCError.operationFailed` if the loop cannot be set.
  public func setABLoop(aPosition: Double, bPosition: Double) throws(VLCError) {
    guard libvlc_media_player_set_abloop_position(pointer, aPosition, bPosition) == 0 else {
      throw .operationFailed("Set A-B loop by position")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Resets (disables) the A-B loop.
  /// - Throws: `VLCError.operationFailed` if the loop cannot be reset.
  public func resetABLoop() throws(VLCError) {
    guard libvlc_media_player_reset_abloop(pointer) == 0 else {
      throw .operationFailed("Reset A-B loop")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Current A-B loop state.
  public var abLoopState: ABLoopState {
    access(keyPath: \.abLoopState)
    var aTime: Int64 = 0
    var aPos: Double = 0
    var bTime: Int64 = 0
    var bPos: Double = 0
    let state = libvlc_media_player_get_abloop(pointer, &aTime, &aPos, &bTime, &bPos)
    return ABLoopState(from: state)
  }

  // MARK: - Video Adjustments

  /// Video color adjustments (contrast, brightness, hue, saturation, gamma).
  public var adjustments: VideoAdjustments {
    VideoAdjustments(player: self)
  }

  /// Scoped access to video adjustments for batched mutations.
  ///
  /// Prefer this over repeated `player.adjustments.x = ...` assignments
  /// when setting several values in sequence:
  /// ```swift
  /// player.withAdjustments { adj in
  ///     adj.isEnabled = true
  ///     adj.contrast = 1.2
  ///     adj.brightness = 1.1
  /// }
  /// ```
  public func withAdjustments<R>(_ body: (borrowing VideoAdjustments) throws -> R) rethrows -> R {
    let adj = VideoAdjustments(player: self)
    return try body(adj)
  }

  /// Text overlay (marquee) controls.
  public var marquee: Marquee {
    Marquee(player: self)
  }

  /// Scoped access to marquee controls for batch operations.
  ///
  /// ```swift
  /// player.withMarquee { m in
  ///     m.isEnabled = true
  ///     m.setText("Now Playing")
  ///     m.fontSize = 24
  /// }
  /// ```
  public func withMarquee<R>(_ body: (borrowing Marquee) throws -> R) rethrows -> R {
    let m = Marquee(player: self)
    return try body(m)
  }

  /// Image overlay (logo) controls.
  public var logo: Logo {
    Logo(player: self)
  }

  /// Scoped access to logo controls for batch operations.
  ///
  /// ```swift
  /// player.withLogo { logo in
  ///     logo.isEnabled = true
  ///     logo.setFile("/path/to/logo.png")
  ///     logo.opacity = 200
  /// }
  /// ```
  public func withLogo<R>(_ body: (borrowing Logo) throws -> R) rethrows -> R {
    let l = Logo(player: self)
    return try body(l)
  }

  /// Updates the 360/VR video viewpoint.
  ///
  /// - Parameters:
  ///   - viewpoint: The new viewpoint values.
  ///   - absolute: If `true`, replaces the current viewpoint. If `false`, adjusts relative to current.
  /// - Throws: `VLCError.operationFailed` if the viewpoint cannot be applied.
  public func updateViewpoint(_ viewpoint: Viewpoint, absolute: Bool = true) throws(VLCError) {
    guard let vp = libvlc_video_new_viewpoint() else { throw .operationFailed("Allocate viewpoint") }
    defer { free(vp) }
    vp.pointee.f_yaw = viewpoint.yaw
    vp.pointee.f_pitch = viewpoint.pitch
    vp.pointee.f_roll = viewpoint.roll
    vp.pointee.f_field_of_view = viewpoint.fieldOfView
    guard libvlc_video_update_viewpoint(pointer, vp, absolute) == 0 else {
      throw .operationFailed("Update viewpoint")
    }
  }

  // MARK: - Teletext

  /// Current teletext page, or 0 if disabled.
  public var teletextPage: Int {
    get {
      access(keyPath: \.teletextPage)
      return Int(libvlc_video_get_teletext(pointer))
    }
    set {
      withMutation(keyPath: \.teletextPage) {
        libvlc_video_set_teletext(pointer, Int32(newValue))
      }
    }
  }

  // MARK: - Equalizer

  /// The audio equalizer applied to this player. Set `nil` to disable.
  ///
  /// Subsequent mutations on the assigned `Equalizer` are re-applied
  /// to the audio output automatically through an installed change
  /// handler. libVLC copies settings on each
  /// `libvlc_media_player_set_equalizer` call and does not retain the
  /// reference.
  public var equalizer: Equalizer? {
    get { _equalizer }
    set {
      _equalizer?.onChange = nil
      _equalizer = newValue
      libvlc_media_player_set_equalizer(pointer, newValue?.pointer)
      newValue?.onChange = { [weak self, weak newValue] in
        guard let self, let newValue else { return }
        libvlc_media_player_set_equalizer(pointer, newValue.pointer)
      }
    }
  }

  // MARK: - Audio Output & Devices

  /// Sets the audio output module.
  /// - Throws: `VLCError.operationFailed` if the module cannot be set.
  public func setAudioOutput(_ name: String) throws(VLCError) {
    guard libvlc_audio_output_set(pointer, name) == 0 else {
      throw .operationFailed("Set audio output '\(name)'")
    }
  }

  /// Lists available audio output devices for the current output.
  public func audioDevices() -> [AudioDevice] {
    guard let list = libvlc_audio_output_device_enum(pointer) else { return [] }
    defer { libvlc_audio_output_device_list_release(list) }

    return sequence(first: list, next: { $0.pointee.p_next }).map { node in
      AudioDevice(
        deviceId: String(cString: node.pointee.psz_device),
        deviceDescription: String(cString: node.pointee.psz_description)
      )
    }
  }

  /// Sets the audio output device.
  /// - Throws: `VLCError.operationFailed` if the device cannot be set.
  public func setAudioDevice(_ deviceId: String) throws(VLCError) {
    guard libvlc_audio_output_device_set(pointer, deviceId) == 0 else {
      throw .operationFailed("Set audio device '\(deviceId)'")
    }
  }

  /// Current audio output device identifier.
  public var currentAudioDevice: String? {
    access(keyPath: \.currentAudioDevice)
    guard let cstr = libvlc_audio_output_device_get(pointer) else { return nil }
    defer { free(cstr) }
    return String(cString: cstr)
  }

  // MARK: - Stereo & Mix Mode

  /// Audio stereo mode.
  public var stereoMode: StereoMode {
    get {
      access(keyPath: \.stereoMode)
      return StereoMode(from: libvlc_audio_get_stereomode(pointer))
    }
    set {
      _ = withMutation(keyPath: \.stereoMode) {
        libvlc_audio_set_stereomode(pointer, newValue.cValue)
      }
    }
  }

  /// Audio mix/channel mode.
  public var mixMode: MixMode {
    get {
      access(keyPath: \.mixMode)
      return MixMode(from: libvlc_audio_get_mixmode(pointer))
    }
    set {
      _ = withMutation(keyPath: \.mixMode) {
        libvlc_audio_set_mixmode(pointer, newValue.cValue)
      }
    }
  }

  // MARK: - Programs (DVB/MPEG-TS)

  /// Lists all available programs in the current media.
  public var programs: [Program] {
    access(keyPath: \.programs)
    guard let list = libvlc_media_player_get_programlist(pointer) else { return [] }
    defer { libvlc_player_programlist_delete(list) }

    let count = libvlc_player_programlist_count(list)
    return (0..<count).compactMap { i in
      libvlc_player_programlist_at(list, i).map { Program(from: $0.pointee) }
    }
  }

  /// The currently selected program.
  public var selectedProgram: Program? {
    access(keyPath: \.selectedProgram)
    guard let prog = libvlc_media_player_get_selected_program(pointer) else { return nil }
    defer { libvlc_player_program_delete(prog) }
    return Program(from: prog.pointee)
  }

  /// Selects a program by its group ID.
  public func selectProgram(id: Int) {
    libvlc_media_player_select_program_id(pointer, Int32(id))
  }

  /// Whether the current program is scrambled (encrypted).
  public var isProgramScrambled: Bool {
    access(keyPath: \.isProgramScrambled)
    return libvlc_media_player_program_scrambled(pointer)
  }

  // MARK: - Renderer (Chromecast / AirPlay)

  /// Sets a renderer for output (e.g. Chromecast).
  ///
  /// Pass `nil` to revert to local playback. libVLC rejects renderer
  /// changes while media is active; this is only valid when the player
  /// is `.idle`, `.stopped`, or `.error`. Call `stop()` first to
  /// reconfigure casting mid-session.
  ///
  /// - Parameter renderer: A ``RendererItem`` discovered by ``RendererDiscoverer``, or `nil`.
  /// - Throws: `VLCError.operationFailed` if the renderer cannot be set,
  ///   or if the player isn't in an idle-like state.
  public func setRenderer(_ renderer: RendererItem?) throws(VLCError) {
    switch state {
    case .idle, .stopped, .error:
      break
    default:
      throw .operationFailed("Set renderer while player is \(state)")
    }
    let result = libvlc_media_player_set_renderer(pointer, renderer?.pointer)
    guard result == 0 else { throw .operationFailed("Set renderer") }
  }

  // MARK: - Deinterlacing

  /// Enables, disables, or sets deinterlacing.
  ///
  /// - Parameters:
  ///   - state: `-1` for auto, `0` to disable, `1` to enable.
  ///   - mode: Deinterlace filter name (e.g. "blend", "bob", "x", "yadif"), or `nil` for default.
  /// - Throws: `VLCError.operationFailed` if the filter cannot be applied.
  public func setDeinterlace(state: Int = -1, mode: String? = nil) throws(VLCError) {
    guard libvlc_video_set_deinterlace(pointer, Int32(state), mode) == 0 else {
      throw .operationFailed("Set deinterlace")
    }
  }

  // MARK: - Track Selection

  private func selectTrack(_ track: Track?, type: TrackType) {
    if let track {
      guard let cTrack = libvlc_media_player_get_track_from_id(pointer, track.id) else {
        return
      }
      libvlc_media_player_select_track(pointer, cTrack)
      libvlc_media_track_release(cTrack)
    } else {
      libvlc_media_player_unselect_track_type(pointer, type.cValue)
    }
    // No eager refresh here. libVLC emits `ESSelected` / `ESUpdated`
    // once the new selection settles (typically <10ms), and the event
    // handler's `refreshTracks()` is the single source of truth. An
    // eager refresh would race libVLC's internal state and briefly
    // show stale `isSelected` flags.
  }

  // MARK: - Video

  private func applyAspectRatio() {
    if let ratioString = aspectRatio.vlcString {
      ratioString.withCString { cstr in
        libvlc_video_set_aspect_ratio(pointer, cstr)
      }
    } else {
      libvlc_video_set_aspect_ratio(pointer, nil)
    }

    switch aspectRatio {
    case .default:
      libvlc_video_set_scale(pointer, 0) // auto
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .ratio:
      // Explicitly reset the fit mode so a prior `.fill` (cover) can't
      // override the new aspect ratio visually.
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .fill:
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_larger)
    }
  }

  // MARK: - Track Refresh

  func refreshTracks() {
    audioTracks = fetchTracks(type: .audio)
    videoTracks = fetchTracks(type: .video)
    subtitleTracks = fetchTracks(type: .subtitle)
    withMutation(keyPath: \.selectedAudioTrack) {}
    withMutation(keyPath: \.selectedSubtitleTrack) {}
  }

  private func fetchTracks(type: TrackType) -> [Track] {
    guard let tracklist = libvlc_media_player_get_tracklist(pointer, type.cValue, false) else {
      return []
    }
    defer { libvlc_media_tracklist_delete(tracklist) }

    let count = libvlc_media_tracklist_count(tracklist)
    return (0..<count).compactMap { i in
      libvlc_media_tracklist_at(tracklist, i).map { Track(from: $0) }
    }
  }

  // MARK: - Event Consumer

  /// Consumes the event stream and mirrors each event onto the
  /// `@Observable` properties that SwiftUI binds to.
  private func startEventConsumer() {
    // Capture eventBridge strongly and self weakly to avoid the retain
    // cycle Player → eventTask → Player.
    let bridge = eventBridge
    eventTask = Task { [weak self] in
      for await event in bridge.makeStream() {
        guard !Task.isCancelled else { return }
        self?.handleEvent(event)
        // Yield after each event so other main-actor work (UI updates,
        // tests, etc.) isn't starved when VLC produces events rapidly.
        await Task.yield()
      }
    }
  }

  private func handleEvent(_ event: PlayerEvent) {
    switch event {
    case .stateChanged(let newState):
      state = newState
      withMutation(keyPath: \.isPlaying) {}
      withMutation(keyPath: \.isActive) {}
      if case .stopped = newState {
        currentTime = .zero
        bufferFill = 0
        withMutation(keyPath: \.position) {
          _position = 0
        }
        withMutation(keyPath: \.abLoopState) {}
      }
      // libVLC doesn't always emit `MediaPlayerLengthChanged`,
      // `MediaPlayerSeekableChanged`, or `MediaPlayerPausableChanged`
      // events on the player side. For some inputs the demuxer publishes
      // those via `MediaParsedChanged` on `Media` (which we don't bridge
      // to the player), or sets the fields before the player has a
      // chance to attach its event listener. Polling on every state
      // transition catches those cases. It's three C calls and is
      // idempotent when the events do fire.
      refreshNativeStateIfNeeded()

    case .timeChanged(let time):
      currentTime = time

    case .positionChanged(let pos):
      withMutation(keyPath: \.position) {
        _position = pos
      }

    case .lengthChanged(let length):
      duration = length

    case .seekableChanged(let seekable):
      isSeekable = seekable

    case .pausableChanged(let pausable):
      isPausable = pausable

    case .tracksChanged:
      refreshTracks()

    case .mediaChanged:
      syncCurrentMediaFromNative()
      resetMediaDerivedState()
      refreshTracks()
      notifyMediaDependentObservables()

    case .encounteredError:
      state = .error
      withMutation(keyPath: \.isPlaying) {}
      withMutation(keyPath: \.isActive) {}

    case .bufferingProgress(let pct):
      // Fill level is useful in every state, so update regardless. A
      // `.paused` player mid-preload still needs to show progress.
      bufferFill = pct
      // Only enter `.buffering` from a pre-play state. Once libVLC is
      // `.playing` or `.paused`, `.stateChanged` drives the lifecycle.
      switch state {
      case .idle, .opening, .buffering:
        if state != .buffering {
          state = .buffering
          withMutation(keyPath: \.isActive) {}
        }
      default:
        break
      }

    // Computed properties read fresh state from libVLC in their getter.
    // An empty `withMutation` is what re-triggers SwiftUI when the
    // underlying C state changes externally (hardware keys, AirPlay,
    // CarPlay, renderer-initiated chapter/title moves). Without this
    // the observers stay pinned to their last read.
    case .volumeChanged:
      withMutation(keyPath: \.volume) {}

    case .muted, .unmuted:
      withMutation(keyPath: \.isMuted) {}

    case .chapterChanged:
      withMutation(keyPath: \.currentChapter) {}

    case .titleSelectionChanged:
      withMutation(keyPath: \.currentTitle) {}

    // Events without a matching observable property are only exposed
    // on the raw `events` stream; consumers that care subscribe there.
    case .audioDeviceChanged:
      withMutation(keyPath: \.currentAudioDevice) {}

    case .programAdded, .programDeleted, .programSelected, .programUpdated:
      withMutation(keyPath: \.programs) {}
      withMutation(keyPath: \.selectedProgram) {}
      withMutation(keyPath: \.isProgramScrambled) {}

    case .corked, .uncorked, .voutChanged,
         .recordingChanged, .titleListChanged, .snapshotTaken,
         .mediaStopping:
      break
    }
  }

  private func resetMediaDerivedState() {
    currentTime = .zero
    duration = nil
    isSeekable = false
    isPausable = false
    bufferFill = 0
    withMutation(keyPath: \.position) {
      _position = 0
    }
  }

  /// Signals every observable whose value is read live from libVLC and
  /// can change when a new media is loaded. libVLC emits no standalone
  /// events for most of these (no `RateChanged`, no `AudioDelayChanged`,
  /// etc. on the player's event manager), so SwiftUI would otherwise
  /// keep showing the pre-swap value. Empty `withMutation` calls force
  /// the getters to re-run next frame.
  private func notifyMediaDependentObservables() {
    withMutation(keyPath: \.rate) {}
    withMutation(keyPath: \.audioDelay) {}
    withMutation(keyPath: \.subtitleDelay) {}
    withMutation(keyPath: \.subtitleTextScale) {}
    withMutation(keyPath: \.role) {}
    withMutation(keyPath: \.stereoMode) {}
    withMutation(keyPath: \.mixMode) {}
    withMutation(keyPath: \.teletextPage) {}
    withMutation(keyPath: \.currentChapter) {}
    withMutation(keyPath: \.currentTitle) {}
    withMutation(keyPath: \.abLoopState) {}
    withMutation(keyPath: \.programs) {}
    withMutation(keyPath: \.selectedProgram) {}
    withMutation(keyPath: \.isProgramScrambled) {}
    withMutation(keyPath: \.currentAudioDevice) {}
    withMutation(keyPath: \.selectedAudioTrack) {}
    withMutation(keyPath: \.selectedSubtitleTrack) {}
  }

  /// Reads length / seekable / pausable directly from libVLC and
  /// publishes any changes to the matching observable property. Called
  /// on every state transition as a resilient companion to
  /// `MediaPlayerLengthChanged` / `SeekableChanged` / `PausableChanged`,
  /// which are not guaranteed to fire on the player's event manager for
  /// every media.
  private func refreshNativeStateIfNeeded() {
    if duration == nil {
      let ms = libvlc_media_player_get_length(pointer)
      if ms > 0 {
        duration = .milliseconds(ms)
      }
    }

    let nativeSeekable = libvlc_media_player_is_seekable(pointer)
    if isSeekable != nativeSeekable {
      isSeekable = nativeSeekable
    }

    let nativePausable = libvlc_media_player_can_pause(pointer)
    if isPausable != nativePausable {
      isPausable = nativePausable
    }

    // libVLC reports volume/mute via `libvlc_audio_get_volume` and
    // `libvlc_audio_get_mute`; both return negative sentinels (observed
    // as `-100` and `-1` respectively on libVLC 4.0) when the audio
    // output isn't initialized yet. Only sync the shadow state from
    // valid (non-negative) reads.
    let nativeVolume = libvlc_audio_get_volume(pointer)
    if nativeVolume >= 0 {
      let normalized = Float(nativeVolume) / 100.0
      if abs(_volume - normalized) > 0.001 {
        withMutation(keyPath: \.volume) {
          _volume = normalized
        }
      }
    }

    let nativeMute = libvlc_audio_get_mute(pointer)
    if nativeMute >= 0 {
      let muted = nativeMute > 0
      if _isMuted != muted {
        withMutation(keyPath: \.isMuted) {
          _isMuted = muted
        }
      }
    }
  }

  private func syncCurrentMediaFromNative() {
    guard let media = libvlc_media_player_get_media(pointer) else {
      currentMedia = nil
      return
    }
    libvlc_media_retain(media)
    currentMedia = Media(retaining: media)
  }

  func _handleEventForTesting(_ event: PlayerEvent) {
    handleEvent(event)
  }

  func _setStateForTesting(
    state: PlayerState? = nil,
    currentTime: Duration? = nil,
    duration: Duration? = nil,
    position: Double? = nil,
    isSeekable: Bool? = nil,
    isPausable: Bool? = nil
  ) {
    if let state {
      self.state = state
    }
    if let currentTime {
      self.currentTime = currentTime
    }
    if let duration {
      self.duration = duration
    }
    if let position {
      _position = position
    }
    if let isSeekable {
      self.isSeekable = isSeekable
    }
    if let isPausable {
      self.isPausable = isPausable
    }
  }
}
