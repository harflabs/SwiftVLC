import CLibVLC
import Foundation
import Observation

/// The central type in SwiftVLC — an observable media player.
///
/// `Player` wraps `libvlc_media_player_t` with `@Observable` and `@MainActor`,
/// so SwiftUI views automatically update when state changes.
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
/// All observable properties (`state`, `currentTime`, `duration`, etc.) are updated
/// automatically via an internal event consumer — no delegates, no Combine, no bridging.
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
    }
  }

  /// Volume level, normalized. 0.0 = silent, 1.0 = normal (100%).
  /// Values above 1.0 amplify beyond normal volume (up to 1.25 = 125%).
  public var volume: Float {
    get {
      access(keyPath: \.volume)
      return Float(libvlc_audio_get_volume(pointer)) / 100.0
    }
    set {
      _ = withMutation(keyPath: \.volume) {
        libvlc_audio_set_volume(pointer, Int32(max(newValue, 0) * 100))
      }
    }
  }

  /// Whether audio is muted.
  public var isMuted: Bool {
    get {
      access(keyPath: \.isMuted)
      return libvlc_audio_get_mute(pointer) > 0
    }
    set {
      withMutation(keyPath: \.isMuted) {
        libvlc_audio_set_mute(pointer, newValue ? 1 : 0)
      }
    }
  }

  /// Playback rate (0.25...4.0, where 1.0 = normal speed).
  public var rate: Float {
    get {
      access(keyPath: \.rate)
      return libvlc_media_player_get_rate(pointer)
    }
    set {
      _ = withMutation(keyPath: \.rate) {
        libvlc_media_player_set_rate(pointer, newValue)
      }
    }
  }

  /// Selected audio track. Set `nil` to use default.
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

  /// Selected subtitle track. Set `nil` to disable subtitles.
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
    state == .playing
  }

  /// Whether playback is active (playing or buffering during playback).
  public var isActive: Bool {
    switch state {
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

  let instance: VLCInstance

  // MARK: - Lifecycle

  /// Creates a new player.
  /// - Parameter instance: The VLC instance to use.
  /// - Throws: `VLCError.instanceCreationFailed` if the player cannot be allocated.
  public init(instance: VLCInstance = .shared) throws(VLCError) {
    guard let p = libvlc_media_player_new(instance.pointer) else {
      throw .instanceCreationFailed
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
    // Detach events while the player pointer is still valid.
    // EventBridge.deinit would also detach, but by then the player
    // (and its event manager) may already be freed → use-after-free.
    eventBridge.invalidate()
    libvlc_media_player_stop_async(pointer)
    libvlc_media_player_release(pointer)
  }

  // MARK: - Media Loading

  /// Loads media for playback.
  ///
  /// The `sending` modifier transfers ownership of the media to the player,
  /// preventing data races across isolation boundaries.
  public func load(_ media: sending Media) {
    currentMedia = media
    libvlc_media_player_set_media(pointer, media.pointer)
    refreshTracks()
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

  /// Toggles play/pause.
  public func togglePlayPause() {
    libvlc_media_player_pause(pointer) // VLC's pause() is actually toggle
  }

  /// Stops playback asynchronously.
  public func stop() {
    libvlc_media_player_stop_async(pointer)
  }

  /// Seeks to an absolute time.
  public func seek(to time: Duration) {
    libvlc_media_player_set_time(pointer, time.milliseconds, /* fast */ false)
  }

  /// Seeks by a relative offset from current position.
  /// Uses VLC 4.0's `jump_time` for efficiency.
  public func seek(by offset: Duration) {
    libvlc_media_player_jump_time(pointer, offset.milliseconds)
  }

  /// Advances to the next video frame (pauses playback if playing).
  public func nextFrame() {
    libvlc_media_player_next_frame(pointer)
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

  /// Takes a snapshot of the current video frame.
  ///
  /// - Parameters:
  ///   - path: File path to save the snapshot.
  ///   - width: Desired width (0 to preserve aspect ratio or use original).
  ///   - height: Desired height (0 to preserve aspect ratio or use original).
  /// - Throws: `VLCError.operationFailed` if the snapshot cannot be taken.
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

    var result: [Title] = []
    for i in 0..<Int(count) {
      guard let desc = cTitles[i]?.pointee else { continue }
      result.append(Title(
        index: i,
        duration: .milliseconds(desc.i_duration),
        name: desc.psz_name.map { String(cString: $0) },
        isMenu: desc.i_flags & UInt32(libvlc_title_menu) != 0,
        isInteractive: desc.i_flags & UInt32(libvlc_title_interactive) != 0
      ))
    }
    return result
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

    var result: [Chapter] = []
    for i in 0..<Int(count) {
      guard let desc = cChapters[i]?.pointee else { continue }
      result.append(Chapter(
        index: i,
        timeOffset: .milliseconds(desc.i_time_offset),
        duration: .milliseconds(desc.i_duration),
        name: desc.psz_name.map { String(cString: $0) }
      ))
    }
    return result
  }

  // MARK: - A-B Loop

  /// Sets an A-B loop using absolute times.
  /// - Throws: `VLCError.operationFailed` if the loop cannot be set.
  public func setABLoop(a: Duration, b: Duration) throws(VLCError) {
    guard libvlc_media_player_set_abloop_time(pointer, a.milliseconds, b.milliseconds) == 0 else {
      throw .operationFailed("Set A-B loop by time")
    }
  }

  /// Sets an A-B loop using fractional positions (0.0...1.0).
  /// - Throws: `VLCError.operationFailed` if the loop cannot be set.
  public func setABLoop(aPosition: Double, bPosition: Double) throws(VLCError) {
    guard libvlc_media_player_set_abloop_position(pointer, aPosition, bPosition) == 0 else {
      throw .operationFailed("Set A-B loop by position")
    }
  }

  /// Resets (disables) the A-B loop.
  /// - Throws: `VLCError.operationFailed` if the loop cannot be reset.
  public func resetABLoop() throws(VLCError) {
    guard libvlc_media_player_reset_abloop(pointer) == 0 else {
      throw .operationFailed("Reset A-B loop")
    }
  }

  /// Current A-B loop state.
  public var abLoopState: ABLoopState {
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
    VideoAdjustments(pointer: pointer)
  }

  /// Text overlay (marquee) controls.
  public var marquee: Marquee {
    Marquee(pointer: pointer)
  }

  /// Image overlay (logo) controls.
  public var logo: Logo {
    Logo(pointer: pointer)
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
  public var equalizer: Equalizer? {
    get { _equalizer }
    set {
      _equalizer = newValue
      libvlc_media_player_set_equalizer(pointer, newValue?.pointer)
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

    var results: [AudioDevice] = []
    var current: UnsafeMutablePointer<libvlc_audio_output_device_t>? = list
    while let node = current {
      let d = node.pointee
      results.append(AudioDevice(
        deviceId: String(cString: d.psz_device),
        deviceDescription: String(cString: d.psz_description)
      ))
      current = d.p_next
    }
    return results
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
    guard let list = libvlc_media_player_get_programlist(pointer) else { return [] }
    defer { libvlc_player_programlist_delete(list) }

    var result: [Program] = []
    let count = libvlc_player_programlist_count(list)
    for i in 0..<count {
      guard let prog = libvlc_player_programlist_at(list, i) else { continue }
      result.append(Program(from: prog.pointee))
    }
    return result
  }

  /// The currently selected program.
  public var selectedProgram: Program? {
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
    libvlc_media_player_program_scrambled(pointer)
  }

  // MARK: - Renderer (Chromecast / AirPlay)

  /// Sets a renderer for output (e.g. Chromecast).
  ///
  /// Pass `nil` to revert to local playback.
  /// - Parameter renderer: A ``RendererItem`` discovered by ``RendererDiscoverer``, or `nil`.
  /// - Throws: `VLCError.operationFailed` if the renderer cannot be set.
  public func setRenderer(_ renderer: RendererItem?) throws(VLCError) {
    let result = if let renderer {
      libvlc_media_player_set_renderer(pointer, renderer.pointer)
    } else {
      libvlc_media_player_set_renderer(pointer, nil)
    }
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
    let result = if let mode {
      libvlc_video_set_deinterlace(pointer, Int32(state), mode)
    } else {
      libvlc_video_set_deinterlace(pointer, Int32(state), nil)
    }
    guard result == 0 else { throw .operationFailed("Set deinterlace") }
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
    refreshTracks()
  }

  // MARK: - Video

  private func applyAspectRatio() {
    switch aspectRatio {
    case .default:
      libvlc_video_set_aspect_ratio(pointer, nil)
      libvlc_video_set_scale(pointer, 0) // Auto
    case .ratio(let w, let h):
      let str = "\(w):\(h)"
      str.withCString { cstr in
        libvlc_video_set_aspect_ratio(pointer, cstr)
      }
    case .fill:
      libvlc_video_set_aspect_ratio(pointer, nil)
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_mode_t(rawValue: 2)) // cover
    }
  }

  // MARK: - Track Refresh

  func refreshTracks() {
    audioTracks = fetchTracks(type: .audio)
    videoTracks = fetchTracks(type: .video)
    subtitleTracks = fetchTracks(type: .subtitle)
  }

  private func fetchTracks(type: TrackType) -> [Track] {
    guard let tracklist = libvlc_media_player_get_tracklist(pointer, type.cValue, false) else {
      return []
    }
    defer { libvlc_media_tracklist_delete(tracklist) }

    var tracks: [Track] = []
    let count = libvlc_media_tracklist_count(tracklist)
    for i in 0..<count {
      guard let cTrack = libvlc_media_tracklist_at(tracklist, i) else { continue }
      tracks.append(Track(from: cTrack))
    }
    return tracks
  }

  // MARK: - Event Consumer

  /// Internal Task that consumes the event stream and updates @Observable properties.
  /// This is what makes Player work with SwiftUI — no external bridging needed.
  private func startEventConsumer() {
    // Capture eventBridge strongly (lightweight object) but self weakly
    // to avoid a retain cycle (Player → eventTask → Player).
    let bridge = eventBridge
    eventTask = Task { [weak self] in
      for await event in bridge.makeStream() {
        guard !Task.isCancelled else { return }
        self?.handleEvent(event)
      }
    }
  }

  private func handleEvent(_ event: PlayerEvent) {
    switch event {
    case .stateChanged(let newState):
      state = newState
      if case .stopped = newState {
        currentTime = .zero
        withMutation(keyPath: \.position) {
          _position = 0
        }
      }

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
      refreshTracks()

    case .encounteredError:
      state = .error

    case .bufferingProgress(let pct):
      // VLC sends buffer-level events continuously during playback.
      // Only show buffering state before playback has started.
      switch state {
      case .idle, .opening, .buffering:
        state = .buffering(pct)
      default:
        break
      }

    case .volumeChanged, .muted, .unmuted, .voutChanged, .chapterChanged,
         .recordingChanged, .titleListChanged, .titleSelectionChanged, .snapshotTaken,
         .programAdded, .programDeleted, .programSelected, .programUpdated:
      break // Observable properties handle these via getters or are consumed via event stream
    }
  }
}
