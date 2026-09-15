import CLibVLC

extension Player {
  func submitNativeSeek(
    operation: NativeSeekOperation,
    evidence: SeekSettlementEvidence,
    publication: SeekOptimisticPublication
  ) -> SeekRequest? {
    // A deferred drawable-safe load has already made the successor current in
    // Swift, but its native player does not exist until `play()`. Reserving a
    // token here would stamp a command against that successor while dispatching
    // it to the retiring handle.
    guard nativeHandleRepresentsCurrentMedia else { return nil }
    intentRevisions.seek &+= 1
    let nativeSeekToken = nativeSeekMonitor.reserveCommand()
    let resolver = SeekOutcomeResolver()
    let command = NativeSeekCommand(
      nativeSeekToken: nativeSeekToken,
      playbackGeneration: sessionGeneration,
      nativeHandleGeneration: eventBridge.currentNativeHandleGeneration,
      externalEpoch: nativeSeekMonitor.externalSeekEpoch,
      timelineRevision: nil,
      dispatchEmissionSequence: nil,
      operation: operation,
      evidence: evidence,
      publication: publication,
      resolver: resolver
    )

    if activeNativeSeek == nil, queuedNativeSeek == nil {
      // Native baseline/duration getters can synchronously pump a tokenless
      // seek callback. Collect every dispatch fact before exposing B in the
      // watcher FIFO, then reject the reservation if that getter advanced the
      // external epoch.
      var dispatchedCommand = finalizeSeekCommandForDispatch(command)
      let finalizedExternalEpoch = nativeSeekMonitor.externalSeekEpoch
      guard finalizedExternalEpoch == command.externalEpoch else {
        nativeSeekMonitor.cancelReservedCommand(nativeSeekToken)
        resolver.resolve(.superseded)
        return SeekRequest(resolver: resolver)
      }
      guard
        nativeSeekMonitor.stageReservedCommandIfIdle(
          nativeSeekToken,
          expectedExternalEpoch: command.externalEpoch
        ) else {
        return queueNativeSeek(command, resolver: resolver)
      }
      dispatchedCommand.timelineRevision = eventBridge.advanceTimelineRevision()
      dispatchedCommand.dispatchEmissionSequence = eventBridge
        .advanceNativeTimelineEmissionSequence()
      activeNativeSeek = makeActiveNativeSeek(for: dispatchedCommand)
      guard issueNativeSeekCommand(dispatchedCommand) == 0 else {
        activeNativeSeek = nil
        nativeSeekMonitor.cancelCommand(nativeSeekToken)
        nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
        resolver.resolve(.rejected)
        return nil
      }
      guard
        nativeSeekMonitor.consumeValidDispatchOwnership(
          nativeSeekToken,
          expectedExternalEpoch: dispatchedCommand.externalEpoch
        ) else {
        // The setter returned, but its staged token was not claimed by an
        // exact synchronous callback, or a tokenless episode interleaved and
        // changed/overlapped ownership. The native request may still drain as
        // a tombstone, but B must never publish or settle from it.
        activeNativeSeek = nil
        nativeSeekMonitor.cancelCommand(nativeSeekToken)
        nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
        resolver.resolve(.superseded)
        return SeekRequest(resolver: resolver)
      }
      latestWrapperDispatchExternalSeekEpoch = max(
        latestWrapperDispatchExternalSeekEpoch,
        dispatchedCommand.externalEpoch
      )
      startActiveNativeSeekDeadline(dispatchedCommand)
      acceptPublicSeekCommand(
        dispatchedCommand,
        allowsPausedFallback: true,
        deadlinePhase: .dispatched
      )
      return SeekRequest(resolver: resolver)
    }

    return queueNativeSeek(command, resolver: resolver)
  }

  func queueNativeSeek(
    _ command: NativeSeekCommand,
    resolver: SeekOutcomeResolver
  ) -> SeekRequest {
    var queuedCommand = rebaseRelativeSeekIfSafe(
      command,
      after: activeNativeSeek?.command
    )
    if let previousQueued = queuedNativeSeek {
      nativeSeekMonitor.cancelReservedCommand(previousQueued.nativeSeekToken)
      previousQueued.resolver.resolve(.superseded)
      queuedCommand = mergeQueuedSeekReplacement(
        queuedCommand,
        replacing: previousQueued
      )
    }
    supersedePublicSeekForNewCommand()
    queuedNativeSeek = queuedCommand
    acceptPublicSeekCommand(
      queuedCommand,
      allowsPausedFallback: false,
      deadlinePhase: .queued
    )
    return SeekRequest(resolver: resolver)
  }

  func makeActiveNativeSeek(for command: NativeSeekCommand) -> ActiveNativeSeek {
    ActiveNativeSeek(
      command: command,
      firstPostEndTimeMilliseconds: nil,
      firstPostEndPosition: nil,
      allowsPausedFallback: nativeSeekMonitor.commandAllowsPausedFallback(
        command.nativeSeekToken
      ),
      isTombstoned: false,
      deadlineTask: nil,
      pollingTask: nil
    )
  }

  /// Bounds a dispatched native owner independently from whichever public
  /// resolver is newest. Superseding A with B cancels A's public deadline, but
  /// A must still be tombstoned if its native episode never terminates. The
  /// tombstone retains the single-flight lease until watched drain evidence or
  /// a true timeline-replacement boundary arrives.
  func startActiveNativeSeekDeadline(_ command: NativeSeekCommand) {
    let nativeSeekToken = command.nativeSeekToken
    let playbackGeneration = command.playbackGeneration
    let deadlineTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      self?.expireActiveNativeSeek(
        nativeSeekToken: nativeSeekToken,
        playbackGeneration: playbackGeneration
      )
    }
    guard
      activeNativeSeek?.command.nativeSeekToken == nativeSeekToken,
      activeNativeSeek?.command.playbackGeneration == playbackGeneration
    else {
      deadlineTask.cancel()
      return
    }
    activeNativeSeek?.deadlineTask = deadlineTask
  }

  func acceptPublicSeekCommand(
    _ command: NativeSeekCommand,
    allowsPausedFallback: Bool,
    deadlinePhase: SeekSettlementDeadlinePhase
  ) {
    supersedePublicSeekForNewCommand()
    cancelPendingFrameSteps()
    pendingSeekSettlement = PendingSeekSettlement(
      playbackGeneration: command.playbackGeneration,
      timelineRevision: command.timelineRevision,
      nativeSeekToken: command.nativeSeekToken,
      resolver: command.resolver,
      baselineTimeMilliseconds: command.evidence.baselineTimeMilliseconds,
      baselinePosition: command.evidence.baselinePosition,
      requestedTimeMilliseconds: command.evidence.requestedTimeMilliseconds,
      requestedPosition: command.evidence.requestedPosition,
      firstPostEndTimeMilliseconds: nil,
      firstPostEndPosition: nil,
      allowsPausedFallback: allowsPausedFallback,
      deadlinePhase: deadlinePhase,
      timeoutTask: nil,
      pollingTask: nil
    )
    if deadlinePhase == .dispatched {
      guard publishDispatchedSeekCommand(command) else { return }
      guard
        pendingSeekSettlement?.nativeSeekToken == command.nativeSeekToken,
        pendingSeekSettlement?.resolver === command.resolver,
        ownsPlaybackMutation(
          command.playbackGeneration,
          nativeHandleGeneration: command.nativeHandleGeneration
        )
      else { return }
      beginRawTimelineQuarantine(for: command)
    }
    startPendingSeekTimeout(command, phase: deadlinePhase)
  }

  /// Starts or restarts the current public deadline. A queued request has a
  /// bounded wait, but native dispatch transitions it to `.dispatched` and
  /// grants a fresh landing window. The captured phase also rejects a queued
  /// timer whose main-actor resumption races that transition after cancellation.
  func startPendingSeekTimeout(
    _ command: NativeSeekCommand,
    phase: SeekSettlementDeadlinePhase
  ) {
    let nativeSeekToken = command.nativeSeekToken
    let resolver = command.resolver
    guard
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === resolver
    else { return }
    pendingSeekSettlement?.timeoutTask?.cancel()
    pendingSeekSettlement?.deadlinePhase = phase
    let timeoutTask = Task { @MainActor [weak self, weak resolver] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard let resolver else { return }
      self?.expirePendingSeek(
        nativeSeekToken: nativeSeekToken,
        resolver: resolver,
        deadlinePhase: phase
      )
    }
    guard
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === resolver
    else {
      timeoutTask.cancel()
      return
    }
    pendingSeekSettlement?.timeoutTask = timeoutTask
  }

  @discardableResult
  func publishDispatchedSeekCommand(_ command: NativeSeekCommand) -> Bool {
    guard
      let timelineRevision = command.timelineRevision,
      let dispatchEmissionSequence = command.dispatchEmissionSequence
    else {
      assertionFailure("A queued seek cannot publish before native dispatch")
      return false
    }
    guard
      ownsPlaybackMutation(
        command.playbackGeneration,
        nativeHandleGeneration: command.nativeHandleGeneration
      )
    else { return false }
    let lifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch
    commitNativeTimelineEmission(dispatchEmissionSequence)
    switch command.publication {
    case .time(let milliseconds):
      return commitSeekTarget(
        milliseconds: milliseconds,
        revision: timelineRevision,
        emissionSequence: dispatchEmissionSequence,
        ifPlaybackGeneration: command.playbackGeneration,
        nativeHandleGeneration: command.nativeHandleGeneration,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
    case .position(let position, let timeMilliseconds):
      acceptedTimelineRevision = timelineRevision
      guard
        performObservableMutation(
          keyPath: \.position,
          ifPlaybackGeneration: command.playbackGeneration,
          nativeHandleGeneration: command.nativeHandleGeneration,
          timelineRevision: timelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch,
          mutation: {
            storePositionWithoutNestedObservation(position)
          }
        )
      else { return false }
      if let timeMilliseconds {
        guard
          performObservableMutation(
            keyPath: \.currentTime,
            ifPlaybackGeneration: command.playbackGeneration,
            nativeHandleGeneration: command.nativeHandleGeneration,
            timelineRevision: timelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch,
            mutation: {
              storeCurrentTimeWithoutNestedObservation(.milliseconds(timeMilliseconds))
            }
          )
        else { return false }
      }
      guard
        recordAuthoritativeTimeline(
          position: position,
          emissionSequence: dispatchEmissionSequence,
          ifPlaybackGeneration: command.playbackGeneration,
          nativeHandleGeneration: command.nativeHandleGeneration,
          timelineRevision: timelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch
        ) else { return false }
      return markPlaybackHealthSeek(
        ifPlaybackGeneration: command.playbackGeneration,
        nativeHandleGeneration: command.nativeHandleGeneration,
        timelineRevision: timelineRevision,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
    case .revisionOnly:
      acceptedTimelineRevision = timelineRevision
      guard
        recordAuthoritativeTimeline(
          position: position,
          emissionSequence: dispatchEmissionSequence,
          ifPlaybackGeneration: command.playbackGeneration,
          nativeHandleGeneration: command.nativeHandleGeneration,
          timelineRevision: timelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch
        ) else { return false }
      return markPlaybackHealthSeek(
        ifPlaybackGeneration: command.playbackGeneration,
        nativeHandleGeneration: command.nativeHandleGeneration,
        timelineRevision: timelineRevision,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
    }
  }

  func beginRawTimelineQuarantine(for command: NativeSeekCommand) {
    guard command.timelineRevision != nil else {
      assertionFailure("A queued seek cannot quarantine the native clock")
      return
    }
    quarantinedSeekTimeline = QuarantinedSeekTimeline(
      nativeSeekToken: command.nativeSeekToken,
      playbackGeneration: command.playbackGeneration,
      nativeHandleGeneration: command.nativeHandleGeneration,
      time: nil,
      timeEmissionSequence: nil,
      position: nil,
      positionEmissionSequence: nil
    )
  }

  /// Retains native clock samples while the request-ID-less watcher belongs
  /// to one dispatched wrapper seek. A command queued behind that owner has
  /// not yet established timeline authority, so callbacks from the active
  /// episode must not make its optimistic/native in-flight clock observable.
  func quarantineSeekTimelineSampleIfNeeded(_ sourcedEvent: SourcedPlayerEvent) -> Bool {
    guard
      let activeNativeSeek,
      activeNativeSeek.command.timelineRevision != nil,
      activeNativeSeek.command.playbackGeneration == sourcedEvent.playbackGeneration,
      quarantinedSeekTimeline?.nativeSeekToken
      == activeNativeSeek.command.nativeSeekToken
    else { return false }

    switch sourcedEvent.event {
    case .timeChanged(let time):
      let sequence = sourcedEvent.nativeSeekEmissionStamp?.timelineEmissionSequence
      let shouldReplace = sequence.map {
        $0 >= (quarantinedSeekTimeline?.timeEmissionSequence ?? 0)
      } ?? true
      if shouldReplace {
        quarantinedSeekTimeline?.time = time
        quarantinedSeekTimeline?.timeEmissionSequence = sequence ?? 0
      }
      return true
    case .positionChanged(let position):
      let sequence = sourcedEvent.nativeSeekEmissionStamp?.timelineEmissionSequence
      let shouldReplace = sequence.map {
        $0 >= (quarantinedSeekTimeline?.positionEmissionSequence ?? 0)
      } ?? true
      if shouldReplace {
        quarantinedSeekTimeline?.position = position
        quarantinedSeekTimeline?.positionEmissionSequence = sequence ?? 0
      }
      return true
    default:
      return false
    }
  }

  func discardQuarantinedSeekTimeline(nativeSeekToken: UInt64) {
    guard quarantinedSeekTimeline?.nativeSeekToken == nativeSeekToken else { return }
    quarantinedSeekTimeline = nil
  }

  func takeQuarantinedSeekTimeline(
    nativeSeekToken: UInt64
  ) -> QuarantinedSeekTimeline? {
    guard quarantinedSeekTimeline?.nativeSeekToken == nativeSeekToken else { return nil }
    defer { quarantinedSeekTimeline = nil }
    return quarantinedSeekTimeline
  }

  /// Replays only samples which entered the shared emission authority after a
  /// committed landing. This handles executor inversion without weakening the
  /// in-flight quarantine: pre-landing samples stay discarded.
  func applyQuarantinedSeekTimeline(
    _ timeline: QuarantinedSeekTimeline,
    afterEmissionSequence minimumSequence: UInt64 = 0
  ) {
    guard
      ownsPlaybackMutation(
        timeline.playbackGeneration,
        nativeHandleGeneration: timeline.nativeHandleGeneration
      )
    else { return }
    var samples: [(sequence: UInt64, event: PlayerEvent)] = []
    if
      let time = timeline.time,
      let sequence = timeline.timeEmissionSequence,
      sequence == 0 || sequence > minimumSequence {
      samples.append((sequence, .timeChanged(time)))
    }
    if
      let position = timeline.position,
      let sequence = timeline.positionEmissionSequence,
      sequence == 0 || sequence > minimumSequence {
      samples.append((sequence, .positionChanged(position)))
    }
    samples.sort { lhs, rhs in lhs.sequence < rhs.sequence }
    for sample in samples where canCommitNativeTimelineEmission(sample.sequence) {
      guard
        ownsPlaybackMutation(
          timeline.playbackGeneration,
          nativeHandleGeneration: timeline.nativeHandleGeneration
        )
      else { return }
      let timelineRevision = acceptedTimelineRevision
      let lifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch
      commitNativeTimelineEmission(sample.sequence)
      handleEvent(
        sample.event,
        sourcePlaybackGeneration: timeline.playbackGeneration,
        sourceNativeHandleGeneration: timeline.nativeHandleGeneration,
        expectedTimelineRevision: timelineRevision,
        sourceLifecycleControlEpoch: lifecycleControlEpoch
      )
      guard
        recordAuthoritativeTimeline(
          position: position,
          emissionSequence: sample.sequence,
          ifPlaybackGeneration: timeline.playbackGeneration,
          nativeHandleGeneration: timeline.nativeHandleGeneration,
          timelineRevision: timelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch
        ) else { return }
    }
  }

  /// Once no newer public command can still dispatch, a timed-out wrapper
  /// request no longer has permission to hide the engine's latest raw clock.
  /// Releasing it updates observable truth without changing the request's
  /// already terminal `.timedOut` outcome.
  func releaseQuarantinedSeekTimelineIfNoSuccessor() {
    guard queuedNativeSeek == nil, let quarantinedSeekTimeline else { return }
    self.quarantinedSeekTimeline = nil
    applyQuarantinedSeekTimeline(quarantinedSeekTimeline)
  }

  func issueNativeSeekCommand(_ command: NativeSeekCommand) -> Int32 {
    // Recheck at the actual dispatch boundary. Finalizing a queued command can
    // synchronously read native state and replacement can win before the setter.
    guard
      nativeHandleRepresentsCurrentMedia,
      ownsPlaybackMutation(
        command.playbackGeneration,
        nativeHandleGeneration: command.nativeHandleGeneration
      )
    else { return -1 }
    if nativeSeekMonitor.supportsVideoOutputEvidence, nativeSeekHasSelectedVideo {
      nativeSeekMonitor.requireVideoOutput(for: command.nativeSeekToken)
    }
    return nativeSeekMonitor.withCausalSeekInvocation(token: command.nativeSeekToken) {
      let result: Int32 = switch command.operation {
      case .time(let milliseconds, let fast):
        issueNativeSeek(toMilliseconds: milliseconds, fast: fast)
      case .position(let position, let fast):
        issueNativeSeek(toPosition: position, fast: fast)
      case .relative(let milliseconds):
        issueNativeJump(byMilliseconds: milliseconds)
      case .strictRelative, .composed:
        // A composition which could not be represented at dispatch (for
        // example, fractional intent after duration became unknown) fails closed.
        -1
      }
      #if DEBUG
      let overrideBypassesNativeStart = switch command.operation {
      case .time: _nativeSetTimeOverrideForTesting != nil
      case .position: _nativeSetPositionOverrideForTesting != nil
      case .relative: _nativeJumpTimeOverrideForTesting != nil
      case .strictRelative, .composed: false
      }
      if result == 0, overrideBypassesNativeStart {
        // Test overrides bypass the real setter's synchronous watcher start.
        // Supply only this exact causal start; an override which already sent
        // the full callback sequence leaves no staged token and this is a no-op.
        nativeSeekMonitor._noteSeekStartedForTesting(
          ifStagedToken: command.nativeSeekToken
        )
      }
      #endif
      return result
    }
  }

  func dispatchQueuedNativeSeekIfPossible() {
    guard
      !isShutdown,
      activeNativeSeek == nil,
      let queuedCommand = queuedNativeSeek,
      queuedCommand.playbackGeneration == sessionGeneration
    else { return }

    let currentExternalEpoch = nativeSeekMonitor.externalSeekEpoch
    guard queuedCommand.externalEpoch == currentExternalEpoch else {
      // A native external start advances this epoch on the callback thread.
      // Do not wait for its independently scheduled MainActor notification:
      // stale queued work must never cross into the watcher FIFO.
      quarantineSeekWork(beforeExternalEpoch: currentExternalEpoch)
      return
    }
    var command = finalizeSeekCommandForDispatch(queuedCommand)
    let finalizedExternalEpoch = nativeSeekMonitor.externalSeekEpoch
    guard queuedCommand.externalEpoch == finalizedExternalEpoch else {
      quarantineSeekWork(beforeExternalEpoch: finalizedExternalEpoch)
      return
    }
    guard
      nativeSeekMonitor.stageReservedCommandIfIdle(
        queuedCommand.nativeSeekToken,
        expectedExternalEpoch: queuedCommand.externalEpoch
      ) else { return }

    command.timelineRevision = eventBridge.advanceTimelineRevision()
    command.dispatchEmissionSequence = eventBridge
      .advanceNativeTimelineEmissionSequence()
    queuedNativeSeek = nil
    activeNativeSeek = makeActiveNativeSeek(for: command)
    guard issueNativeSeekCommand(command) == 0 else {
      activeNativeSeek = nil
      nativeSeekMonitor.cancelCommand(command.nativeSeekToken)
      nativeSeekMonitor.cancelStagedCommand(command.nativeSeekToken)
      finishCurrentPublicSeek(
        nativeSeekToken: command.nativeSeekToken,
        resolver: command.resolver,
        outcome: .rejected
      )
      return
    }
    guard
      nativeSeekMonitor.consumeValidDispatchOwnership(
        command.nativeSeekToken,
        expectedExternalEpoch: command.externalEpoch
      ) else {
      activeNativeSeek = nil
      nativeSeekMonitor.cancelCommand(command.nativeSeekToken)
      nativeSeekMonitor.cancelStagedCommand(command.nativeSeekToken)
      finishCurrentPublicSeek(
        nativeSeekToken: command.nativeSeekToken,
        resolver: command.resolver,
        outcome: .superseded
      )
      return
    }
    latestWrapperDispatchExternalSeekEpoch = max(
      latestWrapperDispatchExternalSeekEpoch,
      command.externalEpoch
    )
    // Publication is an Observation reentrancy boundary. A callback can queue
    // a newer seek while this command remains the sole native owner, so arm its
    // native-owner deadline before publishing any optimistic timeline value.
    startActiveNativeSeekDeadline(command)
    if
      pendingSeekSettlement?.nativeSeekToken == command.nativeSeekToken,
      pendingSeekSettlement?.resolver === command.resolver {
      pendingSeekSettlement?.timelineRevision = command.timelineRevision
      pendingSeekSettlement?.allowsPausedFallback = activeNativeSeek?.allowsPausedFallback ?? false
      pendingSeekSettlement?.baselineTimeMilliseconds =
        command.evidence.baselineTimeMilliseconds
      pendingSeekSettlement?.baselinePosition = command.evidence.baselinePosition
      pendingSeekSettlement?.requestedTimeMilliseconds =
        command.evidence.requestedTimeMilliseconds
      pendingSeekSettlement?.requestedPosition = command.evidence.requestedPosition
    }
    guard publishDispatchedSeekCommand(command) else { return }
    guard
      activeNativeSeek?.command.nativeSeekToken == command.nativeSeekToken,
      ownsPlaybackMutation(
        command.playbackGeneration,
        nativeHandleGeneration: command.nativeHandleGeneration
      )
    else { return }
    beginRawTimelineQuarantine(for: command)
    startPendingSeekTimeout(command, phase: .dispatched)
  }

  func supersedePublicSeekForNewCommand() {
    guard let pendingSeekSettlement else { return }
    self.pendingSeekSettlement = nil
    pendingSeekSettlement.timeoutTask?.cancel()
    pendingSeekSettlement.pollingTask?.cancel()
    if queuedNativeSeek?.nativeSeekToken == pendingSeekSettlement.nativeSeekToken {
      nativeSeekMonitor.cancelReservedCommand(pendingSeekSettlement.nativeSeekToken)
      queuedNativeSeek = nil
    }
    pendingSeekSettlement.resolver.resolve(.superseded)
  }

  func expirePendingSeek(
    nativeSeekToken: UInt64,
    resolver: SeekOutcomeResolver,
    deadlinePhase: SeekSettlementDeadlinePhase
  ) {
    reconcileCommittedNativeSeekProgress()
    guard
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === resolver,
      pendingSeekSettlement?.deadlinePhase == deadlinePhase
    else { return }
    if activeNativeSeek?.command.nativeSeekToken == nativeSeekToken {
      expireActiveNativeSeek(
        nativeSeekToken: nativeSeekToken,
        playbackGeneration: activeNativeSeek?.command.playbackGeneration
      )
      return
    }
    finishCurrentPublicSeek(
      nativeSeekToken: nativeSeekToken,
      resolver: resolver,
      outcome: .timedOut
    )
  }

  func expireActiveNativeSeek(
    nativeSeekToken: UInt64,
    playbackGeneration: UInt64?
  ) {
    reconcileCommittedNativeSeekProgress()
    guard
      var activeNativeSeek,
      activeNativeSeek.command.nativeSeekToken == nativeSeekToken,
      playbackGeneration == nil
      || activeNativeSeek.command.playbackGeneration == playbackGeneration,
      !activeNativeSeek.isTombstoned
    else { return }

    activeNativeSeek.deadlineTask?.cancel()
    activeNativeSeek.deadlineTask = nil
    activeNativeSeek.pollingTask?.cancel()
    activeNativeSeek.pollingTask = nil
    activeNativeSeek.allowsPausedFallback = false
    activeNativeSeek.isTombstoned = true
    self.activeNativeSeek = activeNativeSeek
    // Native work is still running. Keep its observed landing even though
    // the public result is terminal; it must repair time and release the lane.

    if
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === activeNativeSeek.command.resolver {
      finishCurrentPublicSeek(
        nativeSeekToken: nativeSeekToken,
        resolver: activeNativeSeek.command.resolver,
        outcome: .timedOut
      )
    }
    dispatchNextPendingFrameStepIfNeeded()
  }

  var seekBaselineTimeMilliseconds: Int64? {
    guard
      let milliseconds = try? currentTime.checkedMilliseconds(parameter: "currentTime"),
      milliseconds >= 0
    else { return nil }
    return milliseconds
  }

  /// Reads the native clock before dispatch. The observable timeline can
  /// already contain an optimistic target from an earlier seek, so it cannot
  /// prove whether a later post-end getter changed for this command.
  func nativeSeekClockPointForEvidence()
    -> (timeMilliseconds: Int64?, position: Double?) {
    let point: (timeMilliseconds: Int64, position: Double)
    #if DEBUG
    if let override = _nativeSeekBaselineOverrideForTesting {
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
    let time = point.timeMilliseconds >= 0 ? point.timeMilliseconds : nil
    let position = point.position.isFinite && (0.0...1.0).contains(point.position)
      ? point.position
      : nil
    return (time, position)
  }

  func makeSeekSettlementEvidence(
    requestedTimeMilliseconds: Int64?,
    requestedPosition: Double? = nil
  ) -> SeekSettlementEvidence {
    makeSeekSettlementEvidence(
      baseline: nativeSeekClockPointForEvidence(),
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: requestedPosition
    )
  }

  func makeSeekSettlementEvidence(
    baseline nativeBaseline: (timeMilliseconds: Int64?, position: Double?),
    requestedTimeMilliseconds: Int64?,
    requestedPosition: Double? = nil
  ) -> SeekSettlementEvidence {
    let derivedRequestedPosition: Double? = if let requestedPosition {
      requestedPosition
    } else if
      let requestedTimeMilliseconds,
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ),
      durationMilliseconds > 0 {
      min(
        1,
        max(0, Double(requestedTimeMilliseconds) / Double(durationMilliseconds))
      )
    } else {
      nil
    }
    return SeekSettlementEvidence(
      baselineTimeMilliseconds: nativeBaseline.timeMilliseconds,
      baselinePosition: nativeBaseline.position,
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: derivedRequestedPosition
    )
  }

  // Applies the authoritative landed point attributed to the sole serialized
  // native seek episode. Ordinary pre-seek and in-flight time callbacks cannot
  // produce this wrapper token.
}
