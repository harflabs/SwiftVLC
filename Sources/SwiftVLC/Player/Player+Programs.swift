import CLibVLC

/// DVB/MPEG-TS program selection, renderer targeting, and the
/// deinterlace filter.
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

  // MARK: - Renderer

  /// Sets a renderer for output.
  ///
  /// Pass `nil` to revert to local playback. libVLC only applies renderer
  /// selection before the first `play()` call on a native media player.
  /// Set the renderer before starting playback on this ``Player``; to
  /// retarget after playback has started, use ``recast(to:)``.
  ///
  /// > Note: On tvOS the bundled libVLC ships no renderer output
  /// > backends (the Chromecast plugin stack is absent from that binary
  /// > slice), so discovery can surface devices that playback can never
  /// > reach — applying a renderer there does not produce remote output.
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

  /// Switches the active renderer mid-playback on this same `Player` —
  /// drawable attachment, observation, and app-side Now-Playing wiring
  /// all survive. Pass `nil` to return to local playback.
  ///
  /// libVLC applies a renderer only before a native handle's first play,
  /// so this replaces the handle under the hood (the same lazy
  /// replacement a stopped drawable-hosted playback uses), re-applies the
  /// per-player state, and restarts the current media. The call awaits
  /// the **new session**: it resumes from the captured position once the
  /// new session reports seekability (renderer sessions often reject
  /// pre-buffer seeks; live streams never become seekable, so they
  /// restart without a position restore). It never awaits the old
  /// handle's stop — that completes on a background queue and its events
  /// are unobservable; use ``stopAndWait()`` for the explicit-stop path.
  ///
  /// If libVLC rejects the renderer the call throws with the prior
  /// renderer and local playback left intact. A-B loop bounds,
  /// track/chapter/title selection, and DVB program selection reset with
  /// the new session — elementary-stream and program ids can differ per
  /// session, so re-selection is app policy. System Picture-in-Picture
  /// backed by the replaced handle stops when the handle is torn down.
  ///
  /// > Note: On tvOS the bundled libVLC ships no renderer output
  /// > backends — see ``setRenderer(_:)``.
  ///
  /// - Throws: ``VLCError/operationFailed(_:)`` if the renderer is
  ///   rejected (prior renderer and local playback left intact),
  ///   ``VLCError/playbackFailed(reason:)`` if the replacement session
  ///   cannot be started (the renderer is applied at that point — the
  ///   old session is gone; retry `play()` or recast again), or whatever
  ///   ``setRenderer(_:)`` throws on the never-played path. A session
  ///   that starts and *then* fails asynchronously surfaces through
  ///   ``PlayerEvent/encounteredError-enum.case``, not a throw.
  public func recast(to renderer: RendererItem?) async throws(VLCError) {
    guard nativePlayerHasStartedPlayback || state.isActive else {
      try setRenderer(renderer)
      return
    }

    let resumeTime = currentTime
    let wasPlaying = isPlaybackRequestedActive
    let priorRenderer = selectedRenderer
    let priorPointer = pointer
    let priorNeedsReplacement = nativePlayerNeedsReplacementBeforePlayback
    let priorNeedsRebind = needsDrawableRebindForPlayback

    selectedRenderer = renderer
    nativePlayerNeedsReplacementBeforePlayback = true
    let transitions = stateTransitions
    do {
      try play()
    } catch {
      // Restoration is only coherent when the throw happened before the
      // handle replacement committed (renderer rejection releases just
      // the candidate handle). If the replacement went through and the
      // subsequent play call failed, the new renderer is already bound
      // and the old session is gone — rolling the bookkeeping back would
      // make it lie about the native state.
      if pointer == priorPointer {
        selectedRenderer = priorRenderer
        nativePlayerNeedsReplacementBeforePlayback = priorNeedsReplacement
        needsDrawableRebindForPlayback = priorNeedsRebind
      }
      throw error
    }

    await Self.awaitPlaying(on: transitions)
    if resumeTime > .zero, await awaitSeekability() {
      try? seek(to: resumeTime)
    }
    if !wasPlaying {
      pause()
    }
  }

  private static func awaitPlaying(on transitions: AsyncStream<PlayerState>) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in transitions where state == .playing || state == .error {
          break
        }
      }
      group.addTask {
        // Defensive ceiling so a session that never reaches `.playing`
        // cannot hang the caller.
        try? await Task.sleep(for: .seconds(10))
      }
      await group.next()
      group.cancelAll()
    }
  }

  private func awaitSeekability() async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !isSeekable {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
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
    _deinterlaceState = state
    _deinterlaceMode = mode
  }
}
