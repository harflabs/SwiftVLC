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
}
