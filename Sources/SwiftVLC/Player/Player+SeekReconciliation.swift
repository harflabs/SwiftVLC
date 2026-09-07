import CLibVLC

extension Player {
  /// Consumes the callback-lane reservation identified by this wake-up. A
  /// delayed landing task, drain task, and deadline task may execute in any
  /// order on MainActor; only the first can take the exact native fact.
  func nativeSeekDidLand(_ wakeUp: NativeSeekLanding) {
    guard
      let landing = nativeSeekMonitor.consumeSeekLanding(token: wakeUp.token)
    else { return }
    processNativeSeekLanding(landing)
  }

  /// Applies an already-consumed landing. Direct paused fallback and DEBUG
  /// seams call this after winning their own synchronous authority.
  func processNativeSeekLanding(_ landing: NativeSeekLanding) {
    let hasAuthoritativeTime = landing.timeMilliseconds >= 0
    let hasAuthoritativePosition = landing.position.isFinite
      && (0.0...1.0).contains(landing.position)
    guard
      !isShutdown,
      let activeNativeSeek,
      activeNativeSeek.command.nativeSeekToken == landing.token,
      activeNativeSeek.command.playbackGeneration == sessionGeneration,
      activeNativeSeek.command.nativeHandleGeneration
      == eventBridge.currentNativeHandleGeneration,
      hasAuthoritativeTime || hasAuthoritativePosition
    else { return }

    let command = activeNativeSeek.command
    let currentExternalEpoch = nativeSeekMonitor.externalSeekEpoch
    guard command.externalEpoch == currentExternalEpoch else {
      // The callback was emitted before a synchronous external-start epoch
      // advance but reached MainActor afterwards. Retire its older wrapper
      // authority without publishing or staging a stale queued successor.
      quarantineSeekWork(beforeExternalEpoch: currentExternalEpoch)
      return
    }
    let canSettleFromPositionOnly = if
      !hasAuthoritativeTime,
      hasAuthoritativePosition,
      case .position = command.operation {
      true
    } else {
      false
    }
    let hasCoherentLanding = hasAuthoritativeTime || canSettleFromPositionOnly
    guard let commandTimelineRevision = command.timelineRevision else {
      assertionFailure("A native seek landing must belong to a dispatched command")
      return
    }
    activeNativeSeek.deadlineTask?.cancel()
    activeNativeSeek.pollingTask?.cancel()
    self.activeNativeSeek = nil
    let canPublishLanding = hasCoherentLanding
      && canCommitNativeTimelineEmission(landing.emissionSequence)
    let postLandingTimeline = canPublishLanding
      ? takeQuarantinedSeekTimeline(nativeSeekToken: command.nativeSeekToken)
      : nil
    if !canPublishLanding {
      discardQuarantinedSeekTimeline(nativeSeekToken: command.nativeSeekToken)
    }

    // A queued command has not adopted timeline authority yet. Therefore A's
    // sole-episode landing remains the best observable truth even when B has
    // already superseded A's public resolver. B publishes only if its later
    // native dispatch succeeds; rejection deliberately leaves A visible.
    if canPublishLanding, acceptedTimelineRevision == commandTimelineRevision {
      // The landing itself is a new authority boundary. Native event callbacks
      // that entered after dispatch but before seek-start still carry the
      // accepted request revision; advancing here prevents those queued old
      // clock samples from overwriting the landed point after settlement.
      let lifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch
      let landingTimelineRevision = eventBridge.advanceTimelineRevision()
      acceptedTimelineRevision = landingTimelineRevision
      commitNativeTimelineEmission(landing.emissionSequence)
      let authoritativePosition: Double?
      if hasAuthoritativeTime {
        guard
          performObservableMutation(
            keyPath: \.currentTime,
            ifPlaybackGeneration: command.playbackGeneration,
            nativeHandleGeneration: command.nativeHandleGeneration,
            timelineRevision: landingTimelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch,
            mutation: {
              storeCurrentTimeWithoutNestedObservation(
                .milliseconds(landing.timeMilliseconds)
              )
            }
          )
        else { return }
      } else if
        let duration,
        let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
          parameter: "duration"
        ) {
        let landedTime = Duration.milliseconds(checkedMilliseconds(
          for: PlaybackPosition(landing.position),
          durationMs: durationMilliseconds
        ))
        guard
          performObservableMutation(
            keyPath: \.currentTime,
            ifPlaybackGeneration: command.playbackGeneration,
            nativeHandleGeneration: command.nativeHandleGeneration,
            timelineRevision: landingTimelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch,
            mutation: {
              storeCurrentTimeWithoutNestedObservation(landedTime)
            }
          )
        else { return }
      }
      if hasAuthoritativePosition {
        guard
          performObservableMutation(
            keyPath: \.position,
            ifPlaybackGeneration: command.playbackGeneration,
            nativeHandleGeneration: command.nativeHandleGeneration,
            timelineRevision: landingTimelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch,
            mutation: {
              storePositionWithoutNestedObservation(landing.position)
            }
          )
        else { return }
        authoritativePosition = landing.position
      } else {
        authoritativePosition = publishPosition(
          forTargetMilliseconds: landing.timeMilliseconds,
          ifPlaybackGeneration: command.playbackGeneration,
          nativeHandleGeneration: command.nativeHandleGeneration,
          timelineRevision: landingTimelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch
        )
      }
      guard
        recordAuthoritativeTimeline(
          position: authoritativePosition,
          emissionSequence: landing.emissionSequence,
          ifPlaybackGeneration: command.playbackGeneration,
          nativeHandleGeneration: command.nativeHandleGeneration,
          timelineRevision: landingTimelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch
        ) else { return }
      if let postLandingTimeline {
        applyQuarantinedSeekTimeline(
          postLandingTimeline,
          afterEmissionSequence: landing.emissionSequence
        )
      }
    }

    if
      pendingSeekSettlement?.nativeSeekToken == command.nativeSeekToken,
      pendingSeekSettlement?.resolver === command.resolver {
      finishCurrentPublicSeek(
        nativeSeekToken: command.nativeSeekToken,
        resolver: command.resolver,
        outcome: hasCoherentLanding ? .settled : .timedOut
      )
    }
    dispatchQueuedNativeSeekIfPossible()
    dispatchNextPendingFrameStepIfNeeded()
  }

  /// A start with no matching staged token was issued outside SwiftVLC. It
  /// establishes a new external epoch synchronously in the monitor; commands
  /// accepted during that native episode carry the new epoch and wait, while
  /// active/queued work from an older epoch is superseded fail-closed.
  func nativeSeekDidStart(_ start: NativeSeekStart) {
    guard !isShutdown else { return }
    if
      let token = start.token,
      activeNativeSeek?.command.nativeSeekToken == token {
      return
    }

    quarantineSeekWork(beforeExternalEpoch: start.externalEpoch)
    if !nativeSeekMonitor.hasSeekDrainPending {
      dispatchQueuedNativeSeekIfPossible()
    }
  }

  func quarantineSeekWork(beforeExternalEpoch externalEpoch: UInt64) {
    if
      let activeNativeSeek,
      activeNativeSeek.command.externalEpoch < externalEpoch {
      activeNativeSeek.deadlineTask?.cancel()
      activeNativeSeek.pollingTask?.cancel()
      self.activeNativeSeek = nil
      discardQuarantinedSeekTimeline(
        nativeSeekToken: activeNativeSeek.command.nativeSeekToken
      )
      if pendingSeekSettlement?.nativeSeekToken == activeNativeSeek.command.nativeSeekToken {
        finishCurrentPublicSeek(
          nativeSeekToken: activeNativeSeek.command.nativeSeekToken,
          resolver: activeNativeSeek.command.resolver,
          outcome: .superseded
        )
      }
    }

    if
      let queuedNativeSeek,
      queuedNativeSeek.externalEpoch < externalEpoch {
      if pendingSeekSettlement?.nativeSeekToken == queuedNativeSeek.nativeSeekToken {
        finishCurrentPublicSeek(
          nativeSeekToken: queuedNativeSeek.nativeSeekToken,
          resolver: queuedNativeSeek.resolver,
          outcome: .superseded
        )
      } else {
        nativeSeekMonitor.cancelReservedCommand(queuedNativeSeek.nativeSeekToken)
        self.queuedNativeSeek = nil
      }
    }
  }

  /// Reconciles an externally-issued seek even when its start/end/point trio
  /// completed on VLC's callback thread before the main actor processed the
  /// start notification. The epoch is exact for that external episode. A
  /// wrapper command which has already crossed into native code at the same or
  /// a newer epoch has subsequently adopted authority and is never overwritten.
  func nativeExternalSeekDidLand(_ landing: NativeExternalSeekLanding) {
    let hasAuthoritativeTime = landing.timeMilliseconds >= 0
    let hasAuthoritativePosition = landing.position.isFinite
      && (0.0...1.0).contains(landing.position)
    guard
      !isShutdown,
      hasAuthoritativeTime || hasAuthoritativePosition,
      landing.timelineGeneration == nativeSeekMonitor.timelineGeneration,
      landing.nativeHandleGeneration == eventBridge.currentNativeHandleGeneration,
      landing.playbackGeneration == sessionGeneration,
      landing.playbackGeneration == eventBridge.currentPlaybackGeneration,
      landing.externalEpoch == nativeSeekMonitor.externalSeekEpoch,
      landing.externalEpoch > latestAppliedExternalSeekEpoch,
      landing.externalEpoch > latestWrapperDispatchExternalSeekEpoch
    else { return }
    quarantineSeekWork(beforeExternalEpoch: landing.externalEpoch)
    if
      let activeNativeSeek,
      activeNativeSeek.command.timelineRevision != nil,
      activeNativeSeek.command.externalEpoch >= landing.externalEpoch {
      return
    }

    latestAppliedExternalSeekEpoch = landing.externalEpoch
    guard canCommitNativeTimelineEmission(landing.emissionSequence) else {
      // A later raw clock or exact frame callback already committed. Consuming
      // this epoch prevents a duplicate delayed landing from regaining authority.
      dispatchQueuedNativeSeekIfPossible()
      dispatchNextPendingFrameStepIfNeeded()
      return
    }
    commitNativeTimelineEmission(landing.emissionSequence)
    let lifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch
    let revision = eventBridge.advanceTimelineRevision()
    acceptedTimelineRevision = revision
    if hasAuthoritativeTime {
      guard
        performObservableMutation(
          keyPath: \.currentTime,
          ifPlaybackGeneration: landing.playbackGeneration,
          nativeHandleGeneration: landing.nativeHandleGeneration,
          timelineRevision: revision,
          lifecycleControlEpoch: lifecycleControlEpoch,
          mutation: {
            storeCurrentTimeWithoutNestedObservation(.milliseconds(landing.timeMilliseconds))
          }
        )
      else { return }
    } else if
      let durationMilliseconds = currentDurationMilliseconds,
      durationMilliseconds > 0 {
      let landedTime = Duration.milliseconds(checkedMilliseconds(
        for: PlaybackPosition(landing.position),
        durationMs: durationMilliseconds
      ))
      guard
        performObservableMutation(
          keyPath: \.currentTime,
          ifPlaybackGeneration: landing.playbackGeneration,
          nativeHandleGeneration: landing.nativeHandleGeneration,
          timelineRevision: revision,
          lifecycleControlEpoch: lifecycleControlEpoch,
          mutation: {
            storeCurrentTimeWithoutNestedObservation(landedTime)
          }
        )
      else { return }
    }
    let authoritativePosition: Double?
    if hasAuthoritativePosition {
      guard
        performObservableMutation(
          keyPath: \.position,
          ifPlaybackGeneration: landing.playbackGeneration,
          nativeHandleGeneration: landing.nativeHandleGeneration,
          timelineRevision: revision,
          lifecycleControlEpoch: lifecycleControlEpoch,
          mutation: {
            storePositionWithoutNestedObservation(landing.position)
          }
        )
      else { return }
      authoritativePosition = landing.position
    } else {
      authoritativePosition = publishPosition(
        forTargetMilliseconds: landing.timeMilliseconds,
        ifPlaybackGeneration: landing.playbackGeneration,
        nativeHandleGeneration: landing.nativeHandleGeneration,
        timelineRevision: revision,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
    }
    guard
      recordAuthoritativeTimeline(
        position: authoritativePosition,
        emissionSequence: landing.emissionSequence,
        ifPlaybackGeneration: landing.playbackGeneration,
        nativeHandleGeneration: landing.nativeHandleGeneration,
        timelineRevision: revision,
        lifecycleControlEpoch: lifecycleControlEpoch
      ) else { return }
    dispatchQueuedNativeSeekIfPossible()
    dispatchNextPendingFrameStepIfNeeded()
  }

  /// A tombstoned timeout has no landing delivery, but its native end+point
  /// still clears the monitor drain. Release only that tombstone here; a live
  /// command continues to require its sole-episode landing callback.
  func nativeSeekDrainDidClear() {
    reconcileCommittedNativeSeekProgress()
    guard !isShutdown, !nativeSeekMonitor.hasSeekDrainPending else { return }
    if activeNativeSeek?.isTombstoned == true {
      activeNativeSeek?.deadlineTask?.cancel()
      activeNativeSeek?.pollingTask?.cancel()
      activeNativeSeek = nil
    }
    dispatchQueuedNativeSeekIfPossible()
    dispatchNextPendingFrameStepIfNeeded()
  }

  /// A paused input may emit seek-end before its cached getter reflects the
  /// landing. The first watched point remains the primary authority. This path
  /// only starts a bounded fallback poll after leaving the C callback, and it
  /// rejects an unchanged pre-dispatch clock as stale evidence.
  func nativeSeekDidEnd(token: UInt64) {
    guard
      !isShutdown,
      let activeNativeSeek,
      activeNativeSeek.command.nativeSeekToken == token,
      activeNativeSeek.command.playbackGeneration == sessionGeneration,
      activeNativeSeek.allowsPausedFallback,
      !activeNativeSeek.isTombstoned,
      nativePlaybackState == .paused
    else { return }

    pollPausedNativeSeek(token: token)
    guard
      self.activeNativeSeek?.command.nativeSeekToken == token,
      self.activeNativeSeek?.allowsPausedFallback == true,
      self.activeNativeSeek?.pollingTask == nil
    else { return }

    let pollingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(50))
        } catch {
          return
        }
        guard let self else { return }
        guard
          self.activeNativeSeek?.command.nativeSeekToken == token,
          self.activeNativeSeek?.allowsPausedFallback == true,
          self.activeNativeSeek?.isTombstoned == false
        else { return }
        pollPausedNativeSeek(token: token)
      }
    }
    self.activeNativeSeek?.pollingTask = pollingTask
  }

  func pollPausedNativeSeek(token: UInt64) {
    guard
      !isShutdown,
      let activeNativeSeek,
      activeNativeSeek.command.nativeSeekToken == token,
      activeNativeSeek.command.playbackGeneration == sessionGeneration,
      activeNativeSeek.allowsPausedFallback,
      !activeNativeSeek.isTombstoned,
      nativePlaybackState == .paused
    else { return }

    // Seek-end marks the discontinuity, before the sought picture is decoded.
    // Until that picture arrives, get_time can fall back to the input's last
    // pause sample. That sample can differ slightly from the dispatch baseline;
    // repeated reads do not make it a video landing. Selected video must settle
    // from its watched output point. Audio-only inputs retain the getter path
    // because their paused output may not emit another point until resumed.
    guard !nativeSeekHasSelectedVideo else { return }

    let point: (timeMilliseconds: Int64, position: Double)
    #if DEBUG
    if let override = _nativeSeekLandingOverrideForTesting {
      point = override()
    } else {
      point = (
        libvlc_media_player_get_time(pointer),
        libvlc_media_player_get_position(pointer)
      )
    }
    #else
    point = (
      libvlc_media_player_get_time(pointer),
      libvlc_media_player_get_position(pointer)
    )
    #endif

    var updatedPending = pendingMirror(for: activeNativeSeek)
    let isAuthoritative = pausedSeekFallbackIsAuthoritative(
      point,
      pending: &updatedPending
    )
    self.activeNativeSeek?.firstPostEndTimeMilliseconds =
      updatedPending.firstPostEndTimeMilliseconds
    self.activeNativeSeek?.firstPostEndPosition = updatedPending.firstPostEndPosition
    if
      pendingSeekSettlement?.nativeSeekToken == token,
      pendingSeekSettlement?.resolver === activeNativeSeek.command.resolver {
      pendingSeekSettlement?.firstPostEndTimeMilliseconds =
        updatedPending.firstPostEndTimeMilliseconds
      pendingSeekSettlement?.firstPostEndPosition = updatedPending.firstPostEndPosition
    }
    guard isAuthoritative else { return }
    let position = coherentPausedFallbackPosition(point, pending: updatedPending)
    let candidate = NativeSeekLanding(
      token: token,
      timeMilliseconds: point.timeMilliseconds,
      position: position
    )
    guard let claimed = nativeSeekMonitor.claimPausedFallback(candidate) else { return }
    processNativeSeekLanding(claimed)
  }

  private var nativeSeekHasSelectedVideo: Bool {
    #if DEBUG
    if let override = _seekOverridesForTesting.hasSelectedVideo {
      return override
    }
    #endif
    guard let track = libvlc_media_player_get_selected_track(pointer, libvlc_track_video) else {
      return false
    }
    libvlc_media_track_release(track)
    return true
  }

  /// Reconciles facts already committed by the native callback lane before a
  /// deadline or drain wake-up may mutate Player state. Callback handler tasks
  /// are notifications; their executor order is not outcome authority.
  func reconcileCommittedNativeSeekProgress() {
    guard !isShutdown else { return }

    let currentExternalEpoch = nativeSeekMonitor.externalSeekEpoch
    quarantineSeekWork(beforeExternalEpoch: currentExternalEpoch)

    guard let activeToken = activeNativeSeek?.command.nativeSeekToken else {
      return
    }
    if let landing = nativeSeekMonitor.consumeSeekLanding(token: activeToken) {
      processNativeSeekLanding(landing)
      return
    }
    if nativeSeekMonitor.seekEndedAwaitingPointToken == activeToken {
      nativeSeekDidEnd(token: activeToken)
    }
  }

  func pendingMirror(for active: ActiveNativeSeek) -> PendingSeekSettlement {
    PendingSeekSettlement(
      playbackGeneration: active.command.playbackGeneration,
      timelineRevision: active.command.timelineRevision,
      nativeSeekToken: active.command.nativeSeekToken,
      resolver: active.command.resolver,
      baselineTimeMilliseconds: active.command.evidence.baselineTimeMilliseconds,
      baselinePosition: active.command.evidence.baselinePosition,
      requestedTimeMilliseconds: active.command.evidence.requestedTimeMilliseconds,
      requestedPosition: active.command.evidence.requestedPosition,
      firstPostEndTimeMilliseconds: active.firstPostEndTimeMilliseconds,
      firstPostEndPosition: active.firstPostEndPosition,
      allowsPausedFallback: active.allowsPausedFallback,
      deadlinePhase: .dispatched,
      timeoutTask: nil,
      pollingTask: nil
    )
  }

  func pausedSeekFallbackIsAuthoritative(
    _ point: (timeMilliseconds: Int64, position: Double),
    pending: inout PendingSeekSettlement
  ) -> Bool {
    let hasAuthoritativeTime = point.timeMilliseconds >= 0
    let hasAuthoritativePosition = point.position.isFinite
      && (0.0...1.0).contains(point.position)
    let durationEstablishesTimeCoherence: Bool = if
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ) {
      durationMilliseconds > 0
    } else {
      false
    }
    let canUsePositionOnly = !durationEstablishesTimeCoherence
      && pending.requestedPosition != nil
      && hasAuthoritativePosition
    guard hasAuthoritativeTime || canUsePositionOnly else { return false }

    if
      durationEstablishesTimeCoherence,
      hasAuthoritativeTime,
      hasAuthoritativePosition,
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ),
      durationMilliseconds > 0 {
      let positionFromTime = min(
        1,
        max(0, Double(point.timeMilliseconds) / Double(durationMilliseconds))
      )
      guard abs(positionFromTime - point.position) <= 0.001 else {
        // Both getters returned values in their documented domains, so neither
        // may be silently discarded. They are non-atomic and can straddle an
        // update; retain the candidate for diagnostics/stability, but it can
        // never become terminal until a coherent pair is observed.
        pending.firstPostEndTimeMilliseconds = point.timeMilliseconds
        pending.firstPostEndPosition = point.position
        return false
      }
    }

    if
      hasAuthoritativeTime,
      pending.requestedTimeMilliseconds == point.timeMilliseconds {
      return true
    }
    if
      hasAuthoritativeTime,
      let baselineTimeMilliseconds = pending.baselineTimeMilliseconds,
      pending.requestedTimeMilliseconds == baselineTimeMilliseconds,
      point.timeMilliseconds == baselineTimeMilliseconds {
      return true
    }
    if
      canUsePositionOnly,
      let requestedPosition = pending.requestedPosition,
      abs(requestedPosition - point.position) <= 0.000_001 {
      return true
    }

    guard let firstTime = pending.firstPostEndTimeMilliseconds else {
      // A value merely different from the pre-dispatch getter can be the
      // previous rapid seek landing late. Quarantine this first post-end read;
      // only an exact target or a subsequent native transition may settle.
      pending.firstPostEndTimeMilliseconds = point.timeMilliseconds
      pending.firstPostEndPosition = point.position.isFinite ? point.position : nil
      return false
    }
    let positionMatchesFirst: Bool = if let firstPosition = pending.firstPostEndPosition {
      point.position.isFinite && abs(point.position - firstPosition) <= 0.000_001
    } else {
      !point.position.isFinite
    }
    guard point.timeMilliseconds == firstTime, positionMatchesFirst else {
      // A changed candidate begins a new stability probe. This is especially
      // important after the immediate post-end read observed the unchanged
      // baseline and the paused getter catches up one poll later.
      pending.firstPostEndTimeMilliseconds = point.timeMilliseconds
      pending.firstPostEndPosition = point.position.isFinite ? point.position : nil
      return false
    }

    // A single changed getter can still be A's late value during rapid seek
    // overlap. Two identical post-end reads prove a stable native landing,
    // including a legitimate off-target/keyframe landing, but only when that
    // stable pair is observably different from the pre-dispatch baseline.
    let timeDiffersFromBaseline = pending.baselineTimeMilliseconds.map {
      firstTime != $0
    } ?? false
    let positionDiffersFromBaseline: Bool = if
      let firstPosition = pending.firstPostEndPosition,
      let baselinePosition = pending.baselinePosition {
      abs(firstPosition - baselinePosition) > 0.000_001
    } else {
      false
    }
    if durationEstablishesTimeCoherence {
      // Separate libVLC time/position getters are not atomic. With a known
      // duration, a repeated changed fraction beside an unchanged baseline
      // time is incoherent and must never be turned back into that baseline
      // position by `coherentPausedFallbackPosition`.
      return hasAuthoritativeTime && timeDiffersFromBaseline
    }
    return timeDiffersFromBaseline || positionDiffersFromBaseline
  }

  /// The fallback reads libVLC's time and position through separate getters,
  /// so the pair is not an atomic clock point. Derive position from the
  /// authoritative time whenever duration is known. For an unknown-duration
  /// position request, the exact-target or stable-pair checks above establish
  /// authority before the raw fraction is accepted.
  func coherentPausedFallbackPosition(
    _ point: (timeMilliseconds: Int64, position: Double),
    pending: PendingSeekSettlement
  ) -> Double {
    if
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ),
      durationMilliseconds > 0,
      point.timeMilliseconds >= 0 {
      return min(1, max(0, Double(point.timeMilliseconds) / Double(durationMilliseconds)))
    }
    if
      pending.requestedPosition != nil,
      point.position.isFinite,
      (0.0...1.0).contains(point.position) {
      return point.position
    }
    return -.infinity
  }

  /// Resuming makes ordinary clock progress indistinguishable from a paused
  /// fallback landing. Disable only the polling path; the tokenized watch-time
  /// point can still settle the seek if it was already in flight.
  func disablePendingPausedSeekFallback() {
    activeNativeSeek?.allowsPausedFallback = false
    activeNativeSeek?.pollingTask?.cancel()
    activeNativeSeek?.pollingTask = nil
    if
      let activeNativeSeek,
      pendingSeekSettlement?.nativeSeekToken == activeNativeSeek.command.nativeSeekToken {
      pendingSeekSettlement?.allowsPausedFallback = false
    }
  }

  /// Invalidates the current request before another timeline owner is
  /// established.
  func supersedePendingSeekSettlement(ifNotPredating timelineRevision: UInt64? = nil) {
    let latestRevision = max(
      pendingSeekSettlement?.timelineRevision ?? 0,
      max(
        activeNativeSeek?.command.timelineRevision ?? 0,
        queuedNativeSeek?.timelineRevision ?? 0
      )
    )
    if let timelineRevision, timelineRevision < latestRevision {
      return
    }
    supersedeAllSeekWorkForCausalBoundary()
  }

  /// A terminal native state ends the input that could still emit an untagged
  /// seek landing. `handleSourcedEvent` has already validated native-handle
  /// and playback-generation identity before this is called, so a timeline
  /// revision cannot make the terminal state stale. Retire both scheduler
  /// layers and rotate the monitor for every causally matching terminal.
  func supersedeSeekWorkForTerminalBoundary() {
    supersedeAllSeekWorkForCausalBoundary()
    resetNativeSeekMonitorForCausalBoundary()
  }

  /// Rotates the v4 watcher together with all causal identities needed to
  /// reject an external landing that was queued before this boundary.
  func resetNativeSeekMonitorForCausalBoundary() {
    let drainedFrameResults = nativeSeekMonitor.resetForTimelineReplacement(
      nativeHandleGeneration: eventBridge.currentNativeHandleGeneration,
      playbackGeneration: sessionGeneration
    )
    settleFrameStepsAfterAttachmentRetirement(
      drainedResults: drainedFrameResults
    )
  }

  func supersedeAllSeekWorkForCausalBoundary() {
    let pending = pendingSeekSettlement
    pendingSeekSettlement = nil
    pending?.timeoutTask?.cancel()
    pending?.pollingTask?.cancel()
    pending?.resolver.resolve(.superseded)

    activeNativeSeek?.deadlineTask?.cancel()
    activeNativeSeek?.pollingTask?.cancel()
    if let activeNativeSeek {
      nativeSeekMonitor.cancelCommand(activeNativeSeek.command.nativeSeekToken)
    }
    activeNativeSeek = nil
    if let queuedNativeSeek {
      nativeSeekMonitor.cancelReservedCommand(queuedNativeSeek.nativeSeekToken)
    }
    queuedNativeSeek = nil
    quarantinedSeekTimeline = nil
  }

  func finishCurrentPublicSeek(
    nativeSeekToken: UInt64,
    resolver: SeekOutcomeResolver,
    outcome: SeekOutcome
  ) {
    guard
      let pendingSeekSettlement,
      pendingSeekSettlement.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement.resolver === resolver
    else { return }
    self.pendingSeekSettlement = nil
    pendingSeekSettlement.timeoutTask?.cancel()
    pendingSeekSettlement.pollingTask?.cancel()
    if queuedNativeSeek?.nativeSeekToken == nativeSeekToken {
      nativeSeekMonitor.cancelReservedCommand(nativeSeekToken)
      queuedNativeSeek = nil
    }
    resolver.resolve(outcome)
    if outcome == .timedOut {
      releaseQuarantinedSeekTimelineIfNoSuccessor()
    }
    dispatchNextPendingFrameStepIfNeeded()
  }

  #if DEBUG
  /// Deterministic timeout seam; production uses the bounded task above.
  func _expirePendingSeekForTesting(
    deadlinePhase: SeekSettlementDeadlinePhase? = nil
  ) {
    guard let pendingSeekSettlement else { return }
    expirePendingSeek(
      nativeSeekToken: pendingSeekSettlement.nativeSeekToken,
      resolver: pendingSeekSettlement.resolver,
      deadlinePhase: deadlinePhase ?? pendingSeekSettlement.deadlinePhase
    )
  }

  /// Deterministically expires the native-owner watchdog without changing a
  /// newer queued public resolver.
  func _expireActiveNativeSeekForTesting(token: UInt64? = nil) {
    guard let activeNativeSeek else { return }
    let nativeSeekToken = token ?? activeNativeSeek.command.nativeSeekToken
    expireActiveNativeSeek(
      nativeSeekToken: nativeSeekToken,
      playbackGeneration: activeNativeSeek.command.playbackGeneration
    )
  }

  func _completePendingSeekForTesting(
    time: Duration,
    position: Double? = nil,
    token: UInt64? = nil
  ) {
    guard let pendingSeekSettlement else { return }
    let milliseconds = try? time.checkedMilliseconds(parameter: "time")
    processNativeSeekLanding(NativeSeekLanding(
      token: token ?? pendingSeekSettlement.nativeSeekToken,
      timeMilliseconds: milliseconds ?? -1,
      position: position ?? -.infinity
    ))
  }

  func _pollPendingSeekForTesting() {
    guard let token = activeNativeSeek?.command.nativeSeekToken else { return }
    pollPausedNativeSeek(token: token)
  }

  func _expirePendingFrameStepForTesting(token: UInt64? = nil) {
    let frame = if let token {
      pendingFrameSteps.first { $0.requestToken == token }
    } else {
      pendingFrameSteps.first
    }
    guard let frame else { return }
    expirePendingFrameStep(requestToken: frame.requestToken)
  }

  #endif

  /// Whether the player is in a lifecycle state where a lenient seek can
  /// take effect. libVLC 4's seek entry points queue the request under
  /// the player lock and report success even when no media is loaded, so
  /// the no-op `false` contract needs this state gate in front of the
  /// native call. Native state is authoritative whenever it identifies an
  /// established or terminal input. Only `.idle` is ambiguous enough to use
  /// the synchronous active-intent fallback for a same-turn play request.
  var hasLenientSeekSession: Bool {
    guard !isShutdown, nativeHandleRepresentsCurrentMedia else { return false }
    switch nativePlaybackState {
    case .opening, .buffering, .playing, .paused:
      return true
    case .idle:
      return isPlaybackRequestedActive
    case .stopped, .stopping, .error:
      return false
    }
  }
}
