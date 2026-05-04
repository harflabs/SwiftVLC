import CLibVLC

/// DVB/MPEG-TS program selection, renderer (Chromecast/AirPlay)
/// targeting, and the deinterlace filter.
extension Player {
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
    guard let id = Int32(exactly: id) else { return }
    libvlc_media_player_select_program_id(pointer, id)
  }

  /// Whether the current program is scrambled (encrypted).
  public var isProgramScrambled: Bool {
    access(keyPath: \.isProgramScrambled)
    return libvlc_media_player_program_scrambled(pointer)
  }

  // MARK: - Renderer (Chromecast / AirPlay)

  /// Sets a renderer for output (e.g. Chromecast).
  ///
  /// Pass `nil` to revert to local playback. libVLC only applies renderer
  /// selection before the first `play()` call on a native media player.
  /// Set the renderer before starting playback on this ``Player``. To
  /// retarget after local playback has already started, create a fresh
  /// ``Player``, set its renderer, then start playback there.
  ///
  /// - Parameter renderer: A ``RendererItem`` discovered by ``RendererDiscoverer``, or `nil`.
  /// - Throws: `VLCError.operationFailed` if the renderer cannot be set,
  ///   or ``VLCError/invalidState(_:)`` if the player has already started
  ///   playback or isn't in an idle-like state.
  public func setRenderer(_ renderer: RendererItem?) throws(VLCError) {
    switch state {
    case .idle, .stopped, .error:
      break
    default:
      throw .invalidState("setRenderer requires idle, stopped, or error state; current state is \(state)")
    }
    guard !nativePlayerHasStartedPlayback else {
      throw .invalidState("setRenderer must be called before the first play() on this Player")
    }
    let result = libvlc_media_player_set_renderer(pointer, renderer?.pointer)
    guard result == 0 else { throw .operationFailed("Set renderer") }
    selectedRenderer = renderer
  }

  // MARK: - Deinterlacing

  /// Enables, disables, or sets deinterlacing.
  ///
  /// On macOS, libVLC's VideoToolbox path can assert inside its
  /// CVPixelBuffer converter when this filter graph is changed during
  /// active playback. Use a software-decoding ``VLCInstance`` (for
  /// example `--codec=avcodec`) when an app needs interactive
  /// deinterlace controls.
  ///
  /// - Parameters:
  ///   - state: `-1` for auto, `0` to disable, `1` to enable.
  ///   - mode: Deinterlace filter name (e.g. "blend", "bob", "x", "yadif"), or `nil` for default.
  /// - Throws: ``VLCError/invalidInput(_:)`` if `state` cannot be passed to libVLC,
  ///   ``VLCError/invalidState(_:)`` if macOS playback is active on a
  ///   hardware-decoded instance, or ``VLCError/operationFailed(_:)``
  ///   if the filter cannot be applied.
  public func setDeinterlace(state: Int = -1, mode: String? = nil) throws(VLCError) {
    guard [-1, 0, 1].contains(state) else {
      throw .invalidInput("state must be -1 (auto), 0 (off), or 1 (on)")
    }
    let state = try checkedInt32(state, parameter: "state")
    #if os(macOS)
    switch self.state {
    case .idle, .stopped, .error:
      break
    case .opening, .buffering, .playing, .paused, .stopping:
      guard instance.supportsDynamicDeinterlaceChanges else {
        throw .invalidState(
          "Changing deinterlace during active macOS playback requires a software-decoding VLCInstance."
        )
      }
    }
    #endif
    guard libvlc_video_set_deinterlace(pointer, state, mode) == 0 else {
      throw .operationFailed("Set deinterlace")
    }
  }
}
