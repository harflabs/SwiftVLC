import CLibVLC
import Synchronization

/// A cancellation-aware wait owned only by recast. Cancelling this waiter
/// does not cancel or reclassify the native seek; its normal resolver remains
/// alive until the native seek reaches its own terminal outcome.
private final class RecastSeekOutcomeWaiter: Sendable {
  enum Resolution: Sendable {
    case outcome(SeekOutcome)
    case cancelled
  }

  private struct State: Sendable {
    var resolution: Resolution?
    var continuation: CheckedContinuation<Resolution, Never>?
  }

  private let state = Mutex(State())

  func wait() async -> Resolution {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate = state.withLock { state -> Resolution? in
          guard let resolution = state.resolution else {
            state.continuation = continuation
            return nil
          }
          return resolution
        }
        if let immediate {
          continuation.resume(returning: immediate)
        }
      }
    } onCancel: {
      resolve(.cancelled)
    }
  }

  func resolve(_ resolution: Resolution) {
    let continuation = state.withLock { state -> CheckedContinuation<Resolution, Never>? in
      guard state.resolution == nil else { return nil }
      state.resolution = resolution
      defer { state.continuation = nil }
      return state.continuation
    }
    continuation?.resume(returning: resolution)
  }
}

/// DVB/MPEG-TS program selection, renderer targeting, and the
/// deinterlace filter.
extension Player {
  // MARK: - Programs (DVB/MPEG-TS)

  /// Lists all available programs in the current media.
  public var programs: [Program] {
    access(keyPath: \.programs)
    guard nativeHandleRepresentsCurrentMedia else { return [] }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readPrograms)
    #endif
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
    guard nativeHandleRepresentsCurrentMedia else { return nil }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readSelectedProgram)
    #endif
    guard let prog = libvlc_media_player_get_selected_program(pointer) else { return nil }
    defer { libvlc_player_program_delete(prog) }
    return Program(from: prog.pointee)
  }

  /// Selects a program by its group ID.
  public func selectProgram(id: Int) {
    guard nativeHandleRepresentsCurrentMedia else { return }
    guard let id = Int32(exactly: id) else { return }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.selectProgram)
    #endif
    libvlc_media_player_select_program_id(pointer, id)
  }

  /// Whether the current program is scrambled (encrypted).
  public var isProgramScrambled: Bool {
    access(keyPath: \.isProgramScrambled)
    guard nativeHandleRepresentsCurrentMedia else { return false }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readProgramScrambled)
    #endif
    return libvlc_media_player_program_scrambled(pointer)
  }

  // MARK: - Renderer

  /// Sets a renderer for output.
  ///
  /// Pass `nil` to revert to local playback. libVLC only applies renderer
  /// selection before the first `play()` call on a native media player.
  /// Set the renderer before starting playback on this ``Player``; to
  /// retarget after playback has started, use ``recast(to:)``. When `load(_:)`
  /// has already staged a new media for a mandatory fresh handle, this method
  /// safely stages the renderer for that successor without touching the
  /// retiring handle.
  ///
  /// > Note: On tvOS the bundled libVLC ships no renderer output
  /// > backends (the Chromecast plugin stack is absent from that binary
  /// > slice), so discovery can surface devices that playback can never
  /// > reach — applying a renderer there does not produce remote output.
  ///
  /// - Parameter renderer: A ``RendererItem`` discovered by ``RendererDiscoverer``, or `nil`.
  /// - Throws: ``VLCError/operationFailed(_:)`` with `"Set renderer"` if
  ///   the renderer cannot be set,
  ///   or ``VLCError/invalidState(_:)`` if the player has already started
  ///   playback or isn't in an idle-like state.
  public func setRenderer(_ renderer: RendererItem?) throws(VLCError) {
    switch state {
    case .idle, .stopped, .error:
      break
    default:
      throw .invalidState("setRenderer requires idle, stopped, or error state; current state is \(state)")
    }
    if !nativeHandleRepresentsCurrentMedia {
      // The successor has no native handle yet. Renderer choice is per-player
      // configuration, so stage its shadow for the replacement transaction
      // instead of writing it to the retiring media's handle.
      selectedRenderer = renderer
      return
    }
    guard !nativePlayerHasStartedPlayback else {
      throw .invalidState("setRenderer must be called before the first play() on this Player")
    }
    guard setNativeRenderer(renderer, on: pointer) == 0 else {
      throw .operationFailed("Set renderer")
    }
    selectedRenderer = renderer
  }

  /// Applies a renderer through one testable boundary so both initial
  /// selection and replacement-player selection surface the same typed error.
  func setNativeRenderer(_ renderer: RendererItem?, on player: OpaquePointer) -> Int32 {
    #if DEBUG
    _nativeSetRendererTargetHookForTesting?(player, renderer)
    if let _nativeSetRendererOverrideForTesting {
      return _nativeSetRendererOverrideForTesting(renderer)
    }
    #endif
    return libvlc_media_player_set_renderer(player, renderer?.pointer)
  }

  /// Switches the active renderer mid-playback on this same `Player`.
  ///
  /// This compatibility action waits for the same bounded replacement work as
  /// ``recastAndWaitForOutcome(to:)`` but intentionally discards its terminal
  /// outcome. Use that result-bearing method when the caller must distinguish
  /// a settled recast from failure, timeout, cancellation, or supersession.
  public func recast(to renderer: RendererItem?) async throws(VLCError) {
    _ = try await recastAndWaitForOutcome(to: renderer)
  }

  /// Switches or stages the renderer on this same `Player` — drawable
  /// attachment, observation, and app-side Now-Playing wiring all survive.
  /// Pass `nil` to return to local output.
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
  /// selection carry over best-effort — exact ids win; session-scoped ids
  /// fall back only to unique language/name metadata, and an unmatched or
  /// ambiguous track stays at the new session's default. A-B loop bounds, chapter/title
  /// selection, and DVB program selection reset with the new session —
  /// their ids can differ per session, so re-selection is app policy.
  /// A seek, audio/subtitle selection, or pause/resume command issued while
  /// this method is awaiting is newer intent and wins over captured state.
  /// System Picture-in-Picture backed by the replaced handle stops when
  /// the handle is torn down.
  ///
  /// Recasting a previously used handle that is now idle, stopped, or failed
  /// stages the renderer and returns ``RecastOutcome/settled`` without
  /// autoplay; the next explicit `play()` creates and configures a fresh
  /// handle. Media already committed for a deferred fresh handle behaves the
  /// same way without spending another playback generation. In these staged
  /// cases, `settled` does not mean a receiver is already rendering output.
  ///
  /// A ``MediaListPlayer`` owns both list advancement and the shared native
  /// handle while attached. libVLC exposes no atomic "replace this exact list
  /// item" operation, so recast conservatively returns
  /// ``RecastOutcome/superseded`` without changing the player. Detach the
  /// list player first, or use a dedicated ``Player`` for renderer playback.
  ///
  /// > Note: On tvOS the bundled libVLC ships no renderer output
  /// > backends — see ``setRenderer(_:)``.
  ///
  /// - Throws: ``VLCError/operationFailed(_:)`` with `"Set renderer"` if
  ///   the renderer is rejected (prior renderer and local playback left intact),
  ///   ``VLCError/playbackFailed(reason:)`` if the replacement session
  ///   cannot be started (the renderer is applied at that point — the
  ///   old session is gone; retry `play()` or recast again), or whatever
  ///   ``setRenderer(_:)`` throws on the never-played path. A session
  ///   that starts and *then* fails asynchronously surfaces through
  ///   ``PlayerEvent/encounteredError-enum.case``, not a throw.
  public func recastAndWaitForOutcome(
    to renderer: RendererItem?
  )
    async throws(VLCError) -> RecastOutcome {
    if Task.isCancelled || isShutdown {
      return .cancelled
    }
    // A list player can advance the shared native handle from libVLC's own
    // lane while this main-actor method is suspended. There is no C API that
    // atomically verifies and replaces one exact list item, so an identity
    // sample followed by replacement would still be racy. Refuse before any
    // mutation instead.
    guard attachedMediaListPlayer == nil else { return .superseded }

    // B has been published but deliberately has no native handle yet. Recast
    // is configuration only: do not freeze B as a second replacement, touch
    // retiring A, start transport, or spend another playback generation.
    guard nativeHandleRepresentsCurrentMedia else {
      selectedRenderer = renderer
      return .settled
    }

    switch state {
    case .idle, .stopped, .error:
      if nativePlayerHasStartedPlayback {
        // Renderer selection is a pre-first-play native property. A used idle
        // handle cannot be retargeted in place, and recast must not autoplay.
        // Stage the choice and force the next explicit play through a fresh
        // handle, where normal replacement applies it before native play.
        selectedRenderer = renderer
        nativePlayerNeedsReplacementBeforePlayback = true
        needsDrawableRebindForPlayback = drawable != nil
        return .settled
      }
      try setRenderer(renderer)
      return .settled
    case .stopping:
      return .superseded
    case .opening, .buffering, .playing, .paused:
      break
    }

    let ownershipEpoch = mediaListOwnershipEpoch
    let expectedPlaybackGeneration = eventBridge.currentPlaybackGeneration
    guard
      expectedPlaybackGeneration == sessionGeneration,
      expectedPlaybackGeneration < UInt64.max,
      eventBridge.currentNativeHandleGeneration < UInt64.max else {
      return .superseded
    }
    let expectation = RecastReplacementExpectation(
      playbackGeneration: expectedPlaybackGeneration,
      nativeHandleGeneration: eventBridge.currentNativeHandleGeneration,
      lifecycleControlEpoch: eventBridge.currentLifecycleControlEpoch,
      mediaIdentity: currentMedia.map { UInt(bitPattern: $0.pointer) },
      ownershipEpoch: ownershipEpoch
    )
    // Public intent and physical transport state are deliberately separate.
    // A Resume can be authoritative while the observable state still says
    // Paused, while managed audio suspension intentionally keeps active user
    // intent over a physically paused player.
    let shouldRestorePhysicalPause =
      !isPlaybackRequestedActive || preservesPlaybackIntentForManagedAudioSuspension
    let capturedPlaybackControlRevision = playbackControlIntentRevision
    let priorSubtitle = selectedSubtitleTrack
    let priorAudio = selectedAudioTrack
    let priorAudioRevision = intentRevisions.audioTrackSelection
    let priorSubtitleRevision = intentRevisions.subtitleTrackSelection
    let resumeBeforeRelease = shouldResumeNativePlayerBeforeStop
    let statuses = playbackStatus
    guard
      let replacementResult = try replaceNativePlayerForDrawablePlayback(
        target: drawable,
        resumeBeforeRelease: resumeBeforeRelease,
        successorPlaybackGeneration: PlaybackGeneration(
          expectedPlaybackGeneration + 1
        ),
        renderer: .explicit(renderer),
        recastExpectation: expectation
      ) else {
      preconditionFailure("Conditional recast replacement returned no result")
    }
    let lease: RecastReplacementLease
    switch replacementResult {
    case .committed(let committedLease):
      lease = committedLease
    case .interrupted(let interruption):
      return recastOutcome(for: interruption)
    }

    // From here the renderer change has committed and the old session is
    // gone. Its `.playing`, capability, clock, and track arrays are not facts
    // about the replacement even though the media object is unchanged. Reset
    // them before starting the new handle, then publish its real idle state.
    // This guarantees that no bounded wait below can pass without successor
    // evidence.
    let generation = lease.playbackGeneration
    guard
      resetMediaDerivedState(
        preservingPlaybackIntent: true,
        ifPlaybackGeneration: generation
      ) else {
      return recastInterruption(for: lease) ?? .superseded
    }
    if let interruption = recastInterruption(for: lease) {
      return interruption
    }
    guard
      publishPlaybackState(
        .idle,
        ifPlaybackGeneration: generation,
        nativeHandleGeneration: lease.nativeHandleGeneration
      ) else {
      return recastInterruption(for: lease) ?? .superseded
    }
    if let interruption = recastInterruption(for: lease) {
      return interruption
    }

    let playPermit: RecastMutationPermit
    switch eventBridge.reserveRecastMutation(for: lease) {
    case .permitted(let permit):
      playPermit = permit
    case .interrupted(let interruption):
      return recastOutcome(for: interruption)
    }
    guard !Task.isCancelled else {
      eventBridge.abandonRecast(lease)
      return .cancelled
    }
    do {
      try startPlayback(recordsPlaybackControlIntent: false)
    } catch {
      // The replacement is already committed. Rolling back the renderer or
      // generation would describe a handle that no longer exists.
      if let interruption = eventBridge.finishRecastMutation(playPermit) {
        return recastOutcome(for: interruption)
      }
      eventBridge.abandonRecast(lease)
      if Task.isCancelled {
        return .cancelled
      }
      throw error
    }
    if let interruption = eventBridge.finishRecastMutation(playPermit) {
      return recastOutcome(for: interruption)
    }
    let resumeSeekRevision = intentRevisions.seek

    // Scoped to the generation this recast captured, not a re-read of the
    // property. They are equal here, and keeping them textually the same value
    // is what stops a later edit from silently scoping the wait to a session
    // this recast no longer owns.
    let playbackResult = await Self.awaitPlaying(
      on: statuses,
      atLeast: PlaybackGeneration(lease.playbackGeneration),
      timeout: recastWaitTimeout(default: .seconds(10))
    )
    if let interruption = recastInterruption(for: lease) {
      return interruption
    }
    switch playbackResult {
    case .playing:
      break
    case .failed:
      eventBridge.abandonRecast(lease)
      return .failed
    case .timedOut:
      eventBridge.abandonRecast(lease)
      return .timedOut
    case .cancelled:
      eventBridge.abandonRecast(lease)
      return .cancelled
    case .superseded:
      eventBridge.abandonRecast(lease)
      return .superseded
    }

    let resumeTime = lease.outgoingTimeline.time
    if resumeTime > .zero, intentRevisions.seek == resumeSeekRevision {
      switch await awaitSeekability(
        for: generation,
        ownershipEpoch: lease.ownershipEpoch,
        unlessSeekRevisionChangesFrom: resumeSeekRevision,
        timeout: recastWaitTimeout(default: .seconds(2))
      ) {
      case .ready:
        if let interruption = recastInterruption(for: lease) {
          return interruption
        }
        // A newer seek submitted while readiness was pending owns the
        // timeline. Main-actor isolation makes this check and the synchronous
        // request submission indivisible from other public seek calls.
        guard intentRevisions.seek == resumeSeekRevision else { break }
        let seekPermit: RecastMutationPermit
        switch eventBridge.reserveRecastMutation(for: lease) {
        case .permitted(let permit):
          seekPermit = permit
        case .interrupted(let interruption):
          return recastOutcome(for: interruption)
        }
        guard !Task.isCancelled else {
          eventBridge.abandonRecast(lease)
          return .cancelled
        }
        do {
          let request = try requestSeek(to: resumeTime)
          if let interruption = eventBridge.finishRecastMutation(seekPermit) {
            return recastOutcome(for: interruption)
          }
          // Native acceptance is not a landing. Do not call this recast
          // settled while its position restore is still queued or waiting for
          // an authoritative time-watch sample.
          switch await awaitSeekOutcomeRespectingCancellation(request) {
          case .outcome:
            break
          case .cancelled:
            eventBridge.abandonRecast(lease)
            return .cancelled
          }
        } catch {
          if let interruption = eventBridge.finishRecastMutation(seekPermit) {
            return recastOutcome(for: interruption)
          }
          // Position restoration is best-effort: a renderer can withdraw
          // seekability between the readiness sample and dispatch, or reject
          // a target its input cannot represent. The request API guarantees
          // that an accepted request reaches a terminal outcome above.
          if Task.isCancelled || isShutdown {
            eventBridge.abandonRecast(lease)
            return .cancelled
          }
        }
      case .notReady:
        break
      case .cancelled:
        eventBridge.abandonRecast(lease)
        return .cancelled
      }
    }
    if let interruption = recastInterruption(for: lease) {
      return interruption
    }

    if
      let interruption = await restoreTrackSelection(
        audio: priorAudio,
        audioRevision: priorAudioRevision,
        subtitle: priorSubtitle,
        subtitleRevision: priorSubtitleRevision,
        lease: lease,
        timeout: recastWaitTimeout(default: .seconds(3))
      ) {
      return interruption
    }

    if
      shouldRestorePhysicalPause,
      playbackControlIntentRevision == capturedPlaybackControlRevision {
      if let interruption = recastInterruption(for: lease) {
        return interruption
      }
      let pausePermit: RecastMutationPermit
      switch eventBridge.reserveRecastMutation(for: lease) {
      case .permitted(let permit):
        pausePermit = permit
      case .interrupted(let interruption):
        return recastOutcome(for: interruption)
      }
      guard !Task.isCancelled else {
        eventBridge.abandonRecast(lease)
        return .cancelled
      }
      _ = issuePause(
        playbackGeneration: generation,
        recordsPlaybackControlIntent: false
      )
      if let interruption = eventBridge.finishRecastMutation(pausePermit) {
        return recastOutcome(for: interruption)
      }
      // The caller asked for a paused recast, so returning before the pause
      // is acknowledged would report a settled session that is still playing.
      switch await awaitPaused(
        for: generation,
        ownershipEpoch: lease.ownershipEpoch,
        timeout: recastWaitTimeout(default: .seconds(3))
      ) {
      case .ready:
        break
      case .notReady:
        eventBridge.abandonRecast(lease)
        return .timedOut
      case .cancelled:
        eventBridge.abandonRecast(lease)
        return .cancelled
      }
      if let interruption = recastInterruption(for: lease) {
        return interruption
      }
    }
    if Task.isCancelled || isShutdown {
      eventBridge.abandonRecast(lease)
      return .cancelled
    }
    guard
      mediaListOwnershipEpoch == lease.ownershipEpoch,
      attachedMediaListPlayer == nil else {
      eventBridge.abandonRecast(lease)
      return .superseded
    }
    if let interruption = eventBridge.settleRecast(lease) {
      return recastOutcome(for: interruption)
    }
    return .settled
  }

  /// Returns why recast no longer owns a replacement, if anything.
  ///
  private func recastInterruption(
    for lease: RecastReplacementLease
  ) -> RecastOutcome? {
    if Task.isCancelled || isShutdown {
      eventBridge.abandonRecast(lease)
      return .cancelled
    }
    guard
      attachedMediaListPlayer == nil,
      mediaListOwnershipEpoch == lease.ownershipEpoch,
      sessionGeneration == lease.playbackGeneration else {
      eventBridge.abandonRecast(lease)
      return .superseded
    }
    if let interruption = eventBridge.currentRecastInterruption(for: lease) {
      eventBridge.abandonRecast(lease)
      return recastOutcome(for: interruption)
    }
    return nil
  }

  private func recastOutcome(
    for interruption: RecastTransactionInterruption
  ) -> RecastOutcome {
    switch interruption {
    case .superseded:
      .superseded
    case .terminal(.failure):
      .failed
    case .terminal(.cancellation):
      .cancelled
    case .terminal(.naturalEnd),
         .terminal(.requestedStop),
         .terminal(.replacement),
         .terminal(.unknownNativeStop):
      .superseded
    }
  }

  /// Races only this waiter against caller cancellation. The unstructured
  /// observer intentionally remains alive long enough to drain the request's
  /// real terminal outcome; cancellation must not cancel the native seek.
  private func awaitSeekOutcomeRespectingCancellation(
    _ request: SeekRequest
  )
    async -> RecastSeekOutcomeWaiter.Resolution {
    let waiter = RecastSeekOutcomeWaiter()
    Task.detached {
      let outcome = await request.outcome
      waiter.resolve(.outcome(outcome))
    }
    return await waiter.wait()
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
    case superseded
  }

  /// Reapplies the audio and subtitle selection a prior session carried.
  ///
  /// Track ids are session-scoped, so the new session can publish different
  /// ids for the same logical tracks; metadata fallback requires one unique
  /// match and never guesses from discovery order. The new session auto-selects
  /// its default audio, so a track is only reapplied when it differs from what
  /// is already selected. Tracks
  /// arrive after the session reaches `.playing` (adaptive renditions parse
  /// late), so this waits briefly for the lists to populate.
  private func restoreTrackSelection(
    audio: Track?,
    audioRevision: UInt64,
    subtitle: Track?,
    subtitleRevision: UInt64,
    lease: RecastReplacementLease,
    timeout: Duration
  )
    async -> RecastOutcome? {
    guard audio != nil || subtitle != nil else {
      return recastInterruption(for: lease)
    }

    let waited = await awaitCondition(timeout: timeout) {
      guard
        lease.playbackGeneration == self.sessionGeneration,
        lease.playbackGeneration == self.eventBridge.currentPlaybackGeneration,
        lease.ownershipEpoch == self.mediaListOwnershipEpoch,
        !self.isShutdown,
        self.attachedMediaListPlayer == nil,
        !self.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: lease.playbackGeneration
        )
      else { return true }
      let audioReady = audio == nil
        || self.intentRevisions.audioTrackSelection != audioRevision
        || audio.map { Self.matchingTrack(for: $0, in: self.audioTracks) != nil }
        == true
      let subtitleReady = subtitle == nil
        || self.intentRevisions.subtitleTrackSelection != subtitleRevision
        || subtitle.map {
          Self.matchingTrack(for: $0, in: self.subtitleTracks) != nil
        } == true
      return audioReady && subtitleReady
    }
    if waited == .cancelled {
      eventBridge.abandonRecast(lease)
      return .cancelled
    }
    // The lists can still be empty on a timeout; selection below is a no-op
    // then. What must not happen is applying them to a session this recast no
    // longer owns.
    if let interruption = recastInterruption(for: lease) {
      return interruption
    }

    if
      intentRevisions.audioTrackSelection == audioRevision,
      let audio, let match = Self.matchingTrack(for: audio, in: audioTracks),
      match.id != selectedAudioTrack?.id {
      let permit: RecastMutationPermit
      switch eventBridge.reserveRecastMutation(for: lease) {
      case .permitted(let value): permit = value
      case .interrupted(let interruption): return recastOutcome(for: interruption)
      }
      guard !Task.isCancelled else {
        eventBridge.abandonRecast(lease)
        return .cancelled
      }
      selectedAudioTrack = match
      if let interruption = eventBridge.finishRecastMutation(permit) {
        return recastOutcome(for: interruption)
      }
    }
    if let interruption = recastInterruption(for: lease) {
      return interruption
    }
    if
      intentRevisions.subtitleTrackSelection == subtitleRevision,
      let subtitle, let match = Self.matchingTrack(for: subtitle, in: subtitleTracks),
      match.id != selectedSubtitleTrack?.id {
      let permit: RecastMutationPermit
      switch eventBridge.reserveRecastMutation(for: lease) {
      case .permitted(let value): permit = value
      case .interrupted(let interruption): return recastOutcome(for: interruption)
      }
      guard !Task.isCancelled else {
        eventBridge.abandonRecast(lease)
        return .cancelled
      }
      selectedSubtitleTrack = match
      if let interruption = eventBridge.finishRecastMutation(permit) {
        return recastOutcome(for: interruption)
      }
    }
    return recastInterruption(for: lease)
  }

  /// Finds the track in `candidates` that best corresponds to `track` from a
  /// previous session, or from before its unstable id was recreated.
  /// Ambiguous metadata never chooses whichever rendition happened to arrive
  /// first.
  static func matchingTrack(for track: Track, in candidates: [Track]) -> Track? {
    // An unstable id is a per-session counter: the same string can name a
    // different rendition in another session.
    if track.isIDStable, let exact = candidates.first(where: { $0.id == track.id }) {
      return exact
    }
    let candidates = candidates.filter {
      $0.type == track.type
        && ($0.codec == track.codec || $0.codec == 0 || track.codec == 0)
    }
    let language = track.language?.lowercased()
    if let language, !language.isEmpty {
      let exactMetadataMatches = candidates.filter {
        $0.language?.lowercased() == language && $0.name == track.name
      }
      if exactMetadataMatches.count == 1 {
        return exactMetadataMatches[0]
      }
    }
    if let language, !language.isEmpty {
      let languageMatches = candidates.filter {
        $0.language?.lowercased() == language
      }
      if languageMatches.count == 1 {
        return languageMatches[0]
      }
    }
    let nameMatches = candidates.filter { $0.name == track.name }
    return nameMatches.count == 1 ? nameMatches[0] : nil
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
  /// `atLeast` is the exact generation the recast owns. Anything older belongs
  /// to the session it replaced and is ignored, including `.error`. Anything
  /// newer means another operation already took ownership and returns
  /// `.superseded`; its `.playing` or `.error` cannot settle this recast.
  static func awaitPlaying(
    on statuses: AsyncStream<PlaybackStatus>,
    atLeast generation: PlaybackGeneration,
    timeout: Duration = .seconds(10)
  )
    async -> RecastPlaybackResult {
    await withTaskGroup(of: RecastPlaybackResult?.self) { group in
      group.addTask {
        for await status in statuses {
          if Task.isCancelled {
            return .cancelled
          }
          guard status.generation >= generation else { continue }
          guard status.generation == generation else { return .superseded }
          // `.error` is reported rather than silently treated as arrival:
          // the caller needs to know the replacement session failed, not
          // that it is playing.
          if status.state == .playing {
            return .playing
          }
          if status.state == .error {
            return .failed
          }
          if status.state == .stopping || status.state == .stopped {
            // State alone cannot distinguish clean EOF, requested stop, or a
            // replacement boundary. EventBridge preserves the exact cause for
            // the full recast path; the standalone wait remains conservative.
            return .superseded
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

  func awaitSeekability(
    for generation: UInt64? = nil,
    ownershipEpoch: UInt64? = nil,
    unlessSeekRevisionChangesFrom seekRevision: UInt64? = nil,
    timeout: Duration = .seconds(2)
  )
    async -> RecastWaitResult {
    await awaitCondition(timeout: timeout) {
      self.isShutdown
        || self.attachedMediaListPlayer != nil
        || (ownershipEpoch.map { $0 != self.mediaListOwnershipEpoch } ?? false)
        || (seekRevision.map { $0 != self.intentRevisions.seek } ?? false)
        || (generation.map {
          self.eventBridge.hasExplicitStopBarrier(playbackGeneration: $0)
        } ?? false)
        || (generation.map {
          $0 != self.sessionGeneration
            || $0 != self.eventBridge.currentPlaybackGeneration
        } ?? false)
        || self.isSeekable
    }
  }

  func awaitPaused(
    for generation: UInt64? = nil,
    ownershipEpoch: UInt64? = nil,
    timeout: Duration = .seconds(3)
  )
    async -> RecastWaitResult {
    await awaitCondition(timeout: timeout) {
      self.isShutdown
        || self.attachedMediaListPlayer != nil
        || (ownershipEpoch.map { $0 != self.mediaListOwnershipEpoch } ?? false)
        || (generation.map {
          self.eventBridge.hasExplicitStopBarrier(playbackGeneration: $0)
        } ?? false)
        || (generation.map {
          $0 != self.sessionGeneration
            || $0 != self.eventBridge.currentPlaybackGeneration
        } ?? false)
        || self.state == .paused
    }
  }

  /// Uses production recovery budgets unless a DEBUG test deliberately
  /// shortens them. Keeping the seam in one place prevents test-only timing
  /// policy from leaking into the public recast surface.
  private func recastWaitTimeout(default productionTimeout: Duration) -> Duration {
    #if DEBUG
    _recastWaitTimeoutForTesting ?? productionTimeout
    #else
    productionTimeout
    #endif
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
    while true {
      if Task.isCancelled {
        return .cancelled
      }
      if condition() {
        return .ready
      }
      if ContinuousClock.now >= deadline {
        return .notReady
      }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return .cancelled
      }
    }
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
