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
  /// renderer and local playback left intact. The audio and subtitle
  /// selection carry over best-effort — ids are session-scoped, so the
  /// match falls back to language then name, and an unmatched track stays
  /// at the new session's default. A-B loop bounds, chapter/title
  /// selection, and DVB program selection reset with the new session —
  /// their ids can differ per session, so re-selection is app policy.
  /// System Picture-in-Picture backed by the replaced handle stops when
  /// the handle is torn down.
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
  @discardableResult
  public func recast(to renderer: RendererItem?) async throws(VLCError) -> RecastOutcome {
    guard nativePlayerHasStartedPlayback || state.isActive else {
      try setRenderer(renderer)
      return .settled
    }

    let resumeTime = currentTime
    let wasPlaying = isPlaybackRequestedActive
    let priorRenderer = selectedRenderer
    let priorPointer = pointer
    let priorNativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let priorNeedsReplacement = nativePlayerNeedsReplacementBeforePlayback
    let priorNeedsRebind = needsDrawableRebindForPlayback
    let priorSubtitle = selectedSubtitleTrack
    let priorAudio = selectedAudioTrack

    selectedRenderer = renderer
    nativePlayerNeedsReplacementBeforePlayback = true
    let statuses = playbackStatus
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

    // From here the renderer change has committed and the old session is
    // gone, so every remaining step is restoration. Each suspension is a
    // point where the caller can be cancelled or another operation can take
    // over, and past that point this recast must stop mutating the session.
    sessionGeneration = eventBridge.synchronizePlaybackGeneration(
      sessionGeneration &+ 1,
      media: currentMedia?.pointer,
      outgoingNativeHandleGeneration: priorNativeHandleGeneration
    )
    publishPlaybackStatus()
    let generation = sessionGeneration

    // Scoped to the generation this recast captured, not a re-read of the
    // property. They are equal here, and keeping them textually the same value
    // is what stops a later edit from silently scoping the wait to a session
    // this recast no longer owns.
    switch await Self.awaitPlaying(on: statuses, atLeast: PlaybackGeneration(generation)) {
    case .playing:
      break
    case .failed:
      return .failed
    case .timedOut:
      return .timedOut
    case .cancelled:
      return .cancelled
    }
    guard generation == sessionGeneration else { return .superseded }

    if resumeTime > .zero {
      switch await awaitSeekability() {
      case .ready:
        guard generation == sessionGeneration else { return .superseded }
        try? seek(to: resumeTime)
      case .notReady:
        break
      case .cancelled:
        return .cancelled
      }
    }
    guard generation == sessionGeneration else { return .superseded }

    if
      await restoreTrackSelection(
        audio: priorAudio,
        subtitle: priorSubtitle,
        generation: generation
      ) == .cancelled {
      return .cancelled
    }
    guard generation == sessionGeneration else { return .superseded }

    if !wasPlaying {
      pause()
      // The caller asked for a paused recast, so returning before the pause
      // is acknowledged would report a settled session that is still playing.
      switch await awaitPaused() {
      case .ready:
        break
      case .notReady:
        return .timedOut
      case .cancelled:
        return .cancelled
      }
      guard generation == sessionGeneration else { return .superseded }
    }
    return .settled
  }

  /// Why a bounded wait ended. Separate from ``RecastOutcome`` because a
  /// condition that never becomes true is not always fatal to the recast —
  /// an unseekable session still settles, it just keeps its position.
  enum RecastWaitResult {
    case ready
    case notReady
    case cancelled
  }

  /// Why the wait for the replacement session's first playback ended.
  enum RecastPlaybackResult {
    case playing
    case failed
    case timedOut
    case cancelled
  }

  /// Reapplies the audio and subtitle selection a prior session carried.
  ///
  /// Track ids are session-scoped, so the new session publishes different
  /// ids for the same logical tracks; matching falls back to language then
  /// name. The new session auto-selects its default audio, so a track is
  /// only reapplied when it differs from what is already selected. Tracks
  /// arrive after the session reaches `.playing` (adaptive renditions parse
  /// late), so this waits briefly for the lists to populate.
  private func restoreTrackSelection(
    audio: Track?,
    subtitle: Track?,
    generation: UInt64
  )
    async -> RecastWaitResult {
    guard audio != nil || subtitle != nil else { return .ready }

    let waited = await awaitCondition(timeout: .seconds(3)) {
      let audioReady = audio == nil || !self.audioTracks.isEmpty
      let subtitleReady = subtitle == nil || !self.subtitleTracks.isEmpty
      return audioReady && subtitleReady
    }
    if waited == .cancelled {
      return .cancelled
    }
    // The lists can still be empty on a timeout; selection below is a no-op
    // then. What must not happen is applying them to a session this recast no
    // longer owns.
    guard generation == sessionGeneration else { return .ready }

    if
      let audio, let match = Self.matchingTrack(for: audio, in: audioTracks),
      match.id != selectedAudioTrack?.id {
      selectedAudioTrack = match
    }
    if
      let subtitle, let match = Self.matchingTrack(for: subtitle, in: subtitleTracks),
      match.id != selectedSubtitleTrack?.id {
      selectedSubtitleTrack = match
    }
    return .ready
  }

  /// Finds the track in `candidates` that best corresponds to `track` from a
  /// previous session: an exact id match, else the same language, else the
  /// same name.
  static func matchingTrack(for track: Track, in candidates: [Track]) -> Track? {
    if let exact = candidates.first(where: { $0.id == track.id }) {
      return exact
    }
    if
      let language = track.language, !language.isEmpty,
      let byLanguage = candidates.first(where: {
        $0.language?.lowercased() == language.lowercased()
      }) {
      return byLanguage
    }
    return candidates.first { $0.name == track.name }
  }

  /// - Parameter timeout: The defensive ceiling. Injectable so the outcome
  ///   mapping is testable against a synthetic transition stream; CI cannot
  ///   drive a real session to `.playing` (see `TestCondition.canPlayMedia`).
  /// Waits for the *replacement* session to reach `.playing`.
  ///
  /// Scoped by generation rather than matching any `.playing`. A recast
  /// captures its stream before calling `play()`, and same-player media
  /// replacement restarts a session on a repeated `.playing`, so the outgoing
  /// session's own transition is indistinguishable from the incoming one's on
  /// a stream of bare `PlayerState`. Accepting it would report a settled
  /// recast before the replacement had started.
  ///
  /// `atLeast` is the generation the recast owns. Anything older belongs to a
  /// session this recast has already superseded and is ignored, including
  /// `.error`: a failure in the outgoing session is not this recast's failure.
  static func awaitPlaying(
    on statuses: AsyncStream<PlaybackStatus>,
    atLeast generation: PlaybackGeneration,
    timeout: Duration = .seconds(10)
  )
    async -> RecastPlaybackResult {
    await withTaskGroup(of: RecastPlaybackResult?.self) { group in
      group.addTask {
        for await status in statuses {
          guard status.generation >= generation else { continue }
          // `.error` is reported rather than silently treated as arrival:
          // the caller needs to know the replacement session failed, not
          // that it is playing.
          if status.state == .playing {
            return .playing
          }
          if status.state == .error {
            return .failed
          }
        }
        return nil
      }
      group.addTask {
        do {
          try await Task.sleep(for: timeout)
          return .timedOut
        } catch {
          // `Task.sleep` throws only on cancellation. The previous `try?`
          // collapsed this into the timeout path, so a cancelled caller was
          // told the same thing as one that waited the full ceiling.
          return .cancelled
        }
      }
      let result: RecastPlaybackResult = switch await group.next() {
      case .some(.some(let first)):
        first
      default:
        // The transition stream ended without ever reporting playback.
        Task.isCancelled ? .cancelled : .timedOut
      }
      group.cancelAll()
      return result
    }
  }

  func awaitSeekability() async -> RecastWaitResult {
    await awaitCondition(timeout: .seconds(2)) { self.isSeekable }
  }

  func awaitPaused() async -> RecastWaitResult {
    await awaitCondition(timeout: .seconds(3)) { self.state == .paused }
  }

  /// Polls `condition` until it holds, the deadline passes, or the task is
  /// cancelled.
  ///
  /// Cancellation is reported rather than swallowed: the old `try?` kept
  /// polling and then let the caller mutate track selection and transport
  /// state after the caller had already given up.
  func awaitCondition(
    timeout: Duration,
    until condition: @MainActor () -> Bool
  )
    async -> RecastWaitResult {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      if ContinuousClock.now >= deadline {
        return .notReady
      }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return .cancelled
      }
    }
    return .ready
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
