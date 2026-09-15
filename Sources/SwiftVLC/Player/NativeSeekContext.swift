import Synchronization

final class NativeSeekContext: Sendable {
  struct State: Sendable {
    var nextToken: UInt64 = 0
    var timelineGeneration: UInt64 = 1
    var nativeHandleGeneration: UInt64 = 1
    var playbackGeneration: UInt64 = 0
    var reservedTokens: Set<UInt64> = []
    var stagedTokens: [UInt64] = []
    var stagedFrameGenerations: [UInt64: UInt64] = [:]
    var cancelledTokens: Set<UInt64> = []
    /// Wrapper tokens whose start callback was observed while the exact native
    /// setter invocation claim was on the synchronous callback stack. The
    /// scheduler consumes this proof before publishing optimistic state.
    var causallyStartedTokens: Set<UInt64> = []
    /// Tokens whose native seek episode overlapped another unresolved
    /// episode. VLC's time watcher has no request identifier and can emit the
    /// first discontinuity's end after a later seek has started, so neither
    /// that end's point nor a getter read can prove which request landed.
    var overlappedTokens: Set<UInt64> = []
    var activeToken: UInt64?
    var awaitingUpdateToken: UInt64?
    var videoOutputTokens: Set<UInt64> = []
    var expiredVideoOutputToken: UInt64?
    var postEndVideoClockToken: UInt64?
    var lateVideoOutputToken: UInt64?
    /// Exact watched landings committed on VLC's callback lane but not yet
    /// consumed by Player. The callback's MainActor task is only a wake-up;
    /// timeout and drain reconciliation race through this single slot so the
    /// callback fact can win independently of executor scheduling.
    var seekLandingsAwaitingConsumption: [UInt64: NativeSeekLanding] = [:]
    var activeExternalEpoch: UInt64?
    var awaitingUpdateExternalEpoch: UInt64?
    /// Two untagged external starts overlapped before an authoritative
    /// watched point. No later end/point can identify either episode, so the
    /// lane remains fail-closed until an attachment/timeline boundary.
    var externalEpisodeAmbiguous = false
    var frameGeneration: UInt64 = 1
    var activeFrameRequestID: UInt64?
    var retiredFrameRequestIDs: Set<UInt64> = []
    var frameDispatchRetiredSnapshot: Set<UInt64> = []
    var frameRetryBlockerIDs: Set<UInt64> = []
    /// Exact native terminal results not yet consumed by Player's MainActor.
    /// A reservation transports native terminal/output-commit authority across
    /// later task scheduling; Swift callback entry is not itself the semantic
    /// linearization point.
    var frameResultsAwaitingConsumption: [UInt64: NativeFrameStepResult] = [:]
    /// A matched explicit cancellation returned false after native ownership
    /// had been established. In the strict contract, output commit won for
    /// that slot; retain its exact ID until the sole terminal callback arrives
    /// or attachment retirement atomically closes the lane.
    var commitOwnedFrameRequestIDs: Set<UInt64> = []
    var frameResultLaneClosed = false
    var frameQuarantined = false
    var seekDrainPending = false
    var seekEndedAwaitingPoint = false
    var externalSeekEpoch: UInt64 = 0
    var handler: (@Sendable (NativeSeekLanding) -> Void)?
    var seekStartedHandler: (@Sendable (NativeSeekStart) -> Void)?
    var externalSeekLandingHandler: (@Sendable (NativeExternalSeekLanding) -> Void)?
    var seekEndedHandler: (@Sendable (UInt64) -> Void)?
    var seekDrainAvailabilityHandler: (@Sendable () -> Void)?
    var frameHandler: (@Sendable (NativeFrameStepResult) -> Void)?
    var frameInvalidationHandler: (@Sendable (UInt64) -> Void)?
    var frameAvailabilityHandler: (@Sendable () -> Void)?
  }

  // Shared by the output-observation extension; all access remains locked.
  let state: Mutex<State>
  let emissionAuthority: NativeSeekEmissionAuthority

  init(
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64,
    emissionAuthority: NativeSeekEmissionAuthority
  ) {
    self.emissionAuthority = emissionAuthority
    state = Mutex(State(
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration
    ))
  }

  func reserveCommand() -> UInt64 {
    state.withLock { state in
      precondition(state.nextToken < UInt64.max, "Native seek token exhausted")
      state.nextToken += 1
      state.reservedTokens.insert(state.nextToken)
      return state.nextToken
    }
  }

  /// Moves a stable wrapper reservation into VLC's untagged watcher FIFO
  /// only when no native seek episode owns that watcher. This is the v4
  /// single-flight gate; it deliberately claims only sole-episode
  /// attribution, not exact native request identity. Exact identity requires
  /// the future v5 extension.
  func stageReservedCommandIfIdle(
    _ token: UInt64,
    expectedExternalEpoch: UInt64
  ) -> Bool {
    state.withLock { state in
      guard
        state.reservedTokens.contains(token),
        state.externalSeekEpoch == expectedExternalEpoch,
        !state.seekDrainPending,
        state.stagedTokens.isEmpty,
        state.activeToken == nil,
        state.awaitingUpdateToken == nil,
        !state.seekEndedAwaitingPoint
      else { return false }
      precondition(state.frameGeneration < UInt64.max, "Native frame generation exhausted")
      state.reservedTokens.remove(token)
      state.frameGeneration += 1
      state.stagedTokens.append(token)
      state.stagedFrameGenerations[token] = state.frameGeneration
      state.seekDrainPending = true
      return true
    }
  }

  func cancelReservedCommand(_ token: UInt64) {
    state.withLock { state in
      state.reservedTokens.remove(token)
      state.cancelledTokens.remove(token)
      state.videoOutputTokens.remove(token)
      state.causallyStartedTokens.remove(token)
      state.overlappedTokens.remove(token)
      state.seekLandingsAwaitingConsumption.removeValue(forKey: token)
    }
  }

  func stageCommand() -> UInt64 {
    state.withLock { state in
      precondition(state.nextToken < UInt64.max, "Native seek token exhausted")
      precondition(state.frameGeneration < UInt64.max, "Native frame generation exhausted")
      let overlapsUnresolvedSeek = state.seekDrainPending
        || !state.stagedTokens.isEmpty
        || state.activeToken != nil
        || state.awaitingUpdateToken != nil
        || state.seekEndedAwaitingPoint
      state.nextToken += 1
      state.frameGeneration += 1
      state.stagedTokens.append(state.nextToken)
      state.stagedFrameGenerations[state.nextToken] = state.frameGeneration
      if overlapsUnresolvedSeek {
        state.overlappedTokens.insert(state.nextToken)
      }
      state.seekDrainPending = true
      return state.nextToken
    }
  }

  func cancelStagedCommand(_ token: UInt64) {
    typealias Handlers = ((@Sendable () -> Void)?, (@Sendable () -> Void)?)
    let handlers = state.withLock { state -> Handlers in
      if let index = state.stagedTokens.firstIndex(of: token) {
        state.stagedTokens.remove(at: index)
      }
      if
        let stagedGeneration = state.stagedFrameGenerations.removeValue(forKey: token),
        stagedGeneration == state.frameGeneration {
        // A defensive native dispatch failure cannot have exposed this
        // reservation to another main-actor command, so the generation can
        // be rolled back without invalidating the still-live frame queue.
        state.frameGeneration -= 1
      }
      state.cancelledTokens.remove(token)
      state.videoOutputTokens.remove(token)
      state.causallyStartedTokens.remove(token)
      state.overlappedTokens.remove(token)
      state.seekLandingsAwaitingConsumption.removeValue(forKey: token)
      guard
        state.stagedTokens.isEmpty,
        state.activeToken == nil,
        state.awaitingUpdateToken == nil,
        !state.seekEndedAwaitingPoint
      else { return (nil, nil) }
      state.seekDrainPending = false
      return (state.seekDrainAvailabilityHandler, state.frameAvailabilityHandler)
    }
    handlers.0?()
    handlers.1?()
  }

  func cancelCommand(_ token: UInt64) {
    state.withLock { state in
      state.seekLandingsAwaitingConsumption.removeValue(forKey: token)
      let stillOwned = state.stagedTokens.contains(token)
        || state.activeToken == token
        || state.awaitingUpdateToken == token
      guard stillOwned else { return }
      // Keep a dispatched command in the FIFO as a tombstone. Removing it
      // would shift the next seek token onto this command's late start/end
      // callbacks and let an older landing settle a newer rapid seek.
      state.cancelledTokens.insert(token)
      state.videoOutputTokens.remove(token)
      if state.awaitingUpdateToken == token {
        // An overlapped episode is deliberately fail-closed. Its untagged
        // point can never prove that the latest request landed, so retain the
        // exact token and seek drain until a documented causal boundary.
        guard !state.overlappedTokens.contains(token) else { return }
        state.awaitingUpdateToken = nil
        state.cancelledTokens.remove(token)
        state.videoOutputTokens.remove(token)
        state.overlappedTokens.remove(token)
      }
    }
  }

  /// Consumes the callback-stack proof required before public dispatch state
  /// may be published. An external start changes the epoch synchronously; an
  /// overlapping episode marks the otherwise exact wrapper token ambiguous.
  func consumeValidDispatchOwnership(
    _ token: UInt64,
    expectedExternalEpoch: UInt64
  ) -> Bool {
    state.withLock { state in
      let didStartCausally = state.causallyStartedTokens.remove(token) != nil
      return didStartCausally
        && state.externalSeekEpoch == expectedExternalEpoch
        && !state.overlappedTokens.contains(token)
        && (
          state.activeToken == token
            || state.awaitingUpdateToken == token
            || (
              state.activeToken == nil
                && state.awaitingUpdateToken == nil
                && !state.seekDrainPending
            )
        )
    }
  }

  func commandAllowsPausedFallback(_ token: UInt64) -> Bool {
    state.withLock { !$0.overlappedTokens.contains(token) }
  }

  /// Atomically consumes the callback-lane landing authority for `token`.
  /// The delayed handler payload is intentionally not trusted directly: a
  /// timeout, drain wake-up, or the ordinary landing task may get here first,
  /// but exactly one of them can take the reserved fact.
  func consumeSeekLanding(_ token: UInt64) -> NativeSeekLanding? {
    state.withLock { state in
      state.seekLandingsAwaitingConsumption.removeValue(forKey: token)
    }
  }

  /// Returns the exact wrapper token whose seek-end callback has committed but
  /// whose watched point has not arrived. This lets a delayed MainActor end
  /// notification receive one final paused-clock reconciliation before a
  /// timeout becomes authoritative.
  func seekEndedAwaitingPointToken() -> UInt64? {
    state.withLock { state in
      guard
        state.seekEndedAwaitingPoint,
        !state.externalEpisodeAmbiguous,
        let token = state.awaitingUpdateToken,
        !state.overlappedTokens.contains(token),
        !state.cancelledTokens.contains(token)
      else { return nil }
      return token
    }
  }

  /// Claims a direct paused-clock read as the exact terminal evidence for one
  /// non-overlapped seek. The watched-point callback races this operation
  /// through the same mutex, so precisely one path can consume the token.
  func claimPausedFallback(
    _ landing: NativeSeekLanding
  ) -> NativeSeekLanding? {
    typealias Claim = (
      NativeSeekLanding,
      (@Sendable () -> Void)?,
      (@Sendable () -> Void)?
    )
    let claim = state.withLock { state -> Claim? in
      guard
        state.activeToken == nil,
        state.awaitingUpdateToken == landing.token,
        state.seekEndedAwaitingPoint,
        !state.overlappedTokens.contains(landing.token),
        !state.videoOutputTokens.contains(landing.token)
      else { return nil }

      state.awaitingUpdateToken = nil
      state.cancelledTokens.remove(landing.token)
      state.overlappedTokens.remove(landing.token)
      state.seekEndedAwaitingPoint = false
      state.seekDrainPending = !state.stagedTokens.isEmpty || state.activeToken != nil
      if let activeFrameRequestID = state.activeFrameRequestID {
        state.retiredFrameRequestIDs.insert(activeFrameRequestID)
      }
      state.activeFrameRequestID = nil
      state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
      state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
      state.frameQuarantined = false
      let sequencedLanding = NativeSeekLanding(
        token: landing.token,
        timeMilliseconds: landing.timeMilliseconds,
        position: landing.position,
        emissionSequence: emissionAuthority.advanceTimelineEmissionSequence()
      )
      return (
        sequencedLanding,
        state.seekDrainPending ? nil : state.seekDrainAvailabilityHandler,
        state.seekDrainPending ? nil : state.frameAvailabilityHandler
      )
    }
    claim?.1?()
    claim?.2?()
    return claim?.0
  }

  func currentFrameGeneration() -> UInt64 {
    state.withLock { $0.frameGeneration }
  }

  func reserveFrameRequest(
    _ requestID: UInt64,
    frameGeneration: UInt64
  ) -> Bool {
    state.withLock { state in
      guard
        !state.frameResultLaneClosed,
        frameGeneration == state.frameGeneration,
        state.activeFrameRequestID == nil,
        !state.frameQuarantined,
        !state.seekDrainPending
      else { return false }
      Self.retireLateVideoObservation(&state)
      state.activeFrameRequestID = requestID
      state.frameDispatchRetiredSnapshot = state.retiredFrameRequestIDs
      return true
    }
  }

  /// Reconciles an ID-matched native cancellation with native terminal
  /// ownership. Cancellation and output commit have one native linearization
  /// winner. A terminal callback can retire the slot while the C cancellation
  /// is executing; otherwise `false` for the still-matched accepted ID means
  /// output commit won and its sole exact terminal remains authoritative.
  func finishFrameCancellation(
    requestID: UInt64,
    nativeCancelled: Bool
  ) -> Bool {
    typealias Result = (Bool, (@Sendable () -> Void)?)
    let result = state.withLock { state -> Result in
      guard state.activeFrameRequestID == requestID else {
        return (true, nil)
      }
      guard nativeCancelled else {
        state.commitOwnedFrameRequestIDs.insert(requestID)
        state.frameQuarantined = true
        return (false, nil)
      }
      state.activeFrameRequestID = nil
      state.commitOwnedFrameRequestIDs.remove(requestID)
      state.frameQuarantined = false
      return (true, state.frameAvailabilityHandler)
    }
    result.1?()
    return result.0
  }

  func finishFrameDispatch(
    requestID: UInt64,
    disposition: NativeFrameRequestDispatch
  ) -> NativeFrameRequestDispatch {
    state.withLock { state in
      guard state.activeFrameRequestID == requestID else { return disposition }
      switch disposition {
      case .accepted:
        // Acceptance proves no retired request still owns the native slot.
        // Its late exact event remains harmless because IDs never alias.
        state.retiredFrameRequestIDs.removeAll(keepingCapacity: true)
        state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
        state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
        state.frameQuarantined = false
        return .accepted
      case .busy:
        state.activeFrameRequestID = nil
        // A rejected request has no terminal event of its own. Retry only
        // when the busy native slot can be tied to an exact retired ID;
        // otherwise fail closed instead of creating a bool-only tombstone.
        let knownBlockers = state.frameDispatchRetiredSnapshot
        state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
        state.frameRetryBlockerIDs = knownBlockers.intersection(
          state.retiredFrameRequestIDs
        )
        state.frameQuarantined = !state.frameRetryBlockerIDs.isEmpty
        // If a known blocker completed synchronously inside the request,
        // its availability callback is already queued and will retry. Busy
        // with no exact blocker at dispatch entry is an incompatible owner.
        return !knownBlockers.isEmpty ? .busy : .unavailable
      case .unavailable:
        state.activeFrameRequestID = nil
        state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
        return .unavailable
      }
    }
  }

  func clearFrameQuarantineForCausalBoundary() {
    let handler = state.withLock { state -> (@Sendable () -> Void)? in
      let changed = state.activeFrameRequestID != nil || state.frameQuarantined
      if let activeFrameRequestID = state.activeFrameRequestID {
        // Keep the exact retired ID even though the new timeline may proceed.
        // A late terminal event can then be ignored without ever being used
        // as anonymous evidence for a newer request.
        state.retiredFrameRequestIDs.insert(activeFrameRequestID)
      }
      state.activeFrameRequestID = nil
      state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
      state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
      state.frameQuarantined = false
      return changed ? state.frameAvailabilityHandler : nil
    }
    handler?()
  }

  func noteFrameResult(_ result: NativeFrameStepResult) {
    typealias Delivery = (
      NativeFrameStepResult,
      @Sendable (NativeFrameStepResult) -> Void,
      (@Sendable () -> Void)?
    )
    let delivery = state.withLock { state -> Delivery? in
      let releasedActive = state.activeFrameRequestID == result.token
      let releasedRetired = state.retiredFrameRequestIDs.remove(result.token) != nil
      let releasedRetryBlocker = state.frameRetryBlockerIDs.remove(result.token) != nil
      let releasedCommitOwner =
        state.commitOwnedFrameRequestIDs.remove(result.token) != nil
      let hasAuthoritativeTime = result.timeMicroseconds >= 0
      let authoritativePosition = result.position.isFinite
        && (0.0...1.0).contains(result.position)
        ? result.position
        : nil
      let isSuccessful = NativeFrameStepTerminalStatus(rawValue: result.status) == .success
      let emissionSequence = if releasedActive, isSuccessful, hasAuthoritativeTime {
        emissionAuthority.recordTimelineAndAdvance(
          timelineGeneration: state.timelineGeneration,
          playbackGeneration: state.playbackGeneration,
          timeMilliseconds: result.timeMicroseconds / 1000,
          position: authoritativePosition
        )
      } else {
        emissionAuthority.advanceTimelineEmissionSequence()
      }
      let sequencedResult = NativeFrameStepResult(
        token: result.token,
        status: result.status,
        timeMicroseconds: result.timeMicroseconds,
        position: result.position,
        emissionSequence: emissionSequence
      )
      if releasedActive {
        state.activeFrameRequestID = nil
        state.retiredFrameRequestIDs.removeAll(keepingCapacity: true)
        state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
        state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
        state.frameQuarantined = false
      }
      if releasedRetryBlocker, state.frameRetryBlockerIDs.isEmpty {
        state.frameQuarantined = false
      }
      let reservesPlayerResult = !state.frameResultLaneClosed
        && (releasedActive || releasedCommitOwner)
      if reservesPlayerResult {
        /* Request identifiers never alias. A second result for one active
         * generation would violate the native sole-terminal contract and
         * must not replace the first exact native terminal. */
        state.frameResultsAwaitingConsumption[result.token] =
          state.frameResultsAwaitingConsumption[result.token] ?? sequencedResult
      }
      guard
        reservesPlayerResult || releasedRetired || releasedRetryBlocker,
        let handler = state.frameHandler
      else {
        return nil
      }
      return (
        sequencedResult,
        handler,
        releasedActive || releasedRetired || releasedRetryBlocker
          || releasedCommitOwner
          ? state.frameAvailabilityHandler
          : nil
      )
    }
    guard let delivery else { return }
    delivery.1(delivery.0)
    delivery.2?()
  }

  func consumeFrameResult(requestID: UInt64) -> NativeFrameStepResult? {
    state.withLock { state in
      state.frameResultsAwaitingConsumption.removeValue(forKey: requestID)
    }
  }

  /// Permanently closes result ownership before Player teardown. The mutex is
  /// the lifecycle linearization point: callbacks entering afterward may
  /// drain native bookkeeping but can no longer strand or rewrite a public
  /// resolver whose owner is being destroyed.
  func closeFrameResultLane() -> [NativeFrameStepResult] {
    state.withLock { state in
      state.frameResultLaneClosed = true
      let results = state.frameResultsAwaitingConsumption.values
        .sorted { $0.emissionSequence < $1.emissionSequence }
      state.frameResultsAwaitingConsumption.removeAll(keepingCapacity: false)
      state.commitOwnedFrameRequestIDs.removeAll(keepingCapacity: false)
      state.activeFrameRequestID = nil
      state.retiredFrameRequestIDs.removeAll(keepingCapacity: false)
      state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: false)
      state.frameRetryBlockerIDs.removeAll(keepingCapacity: false)
      state.frameQuarantined = false
      return results
    }
  }

  #if DEBUG
  func seekLandingReservationCountForTesting() -> Int {
    state.withLock { $0.seekLandingsAwaitingConsumption.count }
  }

  func frameResultAuthorityCounts() -> (reservations: Int, commitOwners: Int) {
    state.withLock {
      ($0.frameResultsAwaitingConsumption.count, $0.commitOwnedFrameRequestIDs.count)
    }
  }
  #endif

  enum SeekStartAttribution: Sendable {
    /// No exact setter invocation owns this callback. A staged reservation is
    /// intentionally left untouched and this start advances the external epoch.
    case external
    /// Exact native setter whose synchronous callback stack is active.
    case causalWrapper(UInt64)
    /// Deterministic compatibility seam used by direct monitor unit tests.
    /// It consumes a staged token if present, but carries no production proof.
    case legacyTesting
    /// Auto-completion for a DEBUG setter override. If the override already
    /// supplied the callback, this is a no-op rather than a phantom external seek.
    case exactTesting(UInt64)
  }

  func noteSeekStarted(
    timelineGeneration: UInt64,
    attribution: SeekStartAttribution
  ) {
    typealias FrameInvalidation = (UInt64, @Sendable (UInt64) -> Void)
    typealias Delivery = (FrameInvalidation?, NativeSeekStart, (@Sendable (NativeSeekStart) -> Void)?)
    let delivery = state.withLock { state -> Delivery? in
      guard timelineGeneration == state.timelineGeneration else { return nil }
      let stagedToken: UInt64?
      let isCausallyAttributed: Bool
      switch attribution {
      case .external:
        stagedToken = nil
        isCausallyAttributed = false

      case .causalWrapper(let token):
        guard state.stagedTokens.first == token else { return nil }
        stagedToken = token
        isCausallyAttributed = true

      case .legacyTesting:
        if state.stagedTokens.isEmpty, state.activeToken != nil {
          // Most older tests supplied the wrapper start after the DEBUG setter
          // returned. DEBUG setters now auto-supply exact causal starts; ignore
          // that redundant legacy notification without weakening the explicit
          // external testing seam.
          return nil
        }
        stagedToken = state.stagedTokens.first
        isCausallyAttributed = false

      case .exactTesting(let token):
        guard state.stagedTokens.first == token else { return nil }
        stagedToken = token
        isCausallyAttributed = true
      }

      Self.retireLateVideoObservation(&state)
      let hasStagedWrapperReservation = !state.stagedTokens.isEmpty
      let overlapsWrapperEpisode = state.activeToken != nil
        || state.awaitingUpdateToken != nil
      let overlapsExternalEpisode = state.activeExternalEpoch != nil
        || state.awaitingUpdateExternalEpoch != nil
        || (
          !hasStagedWrapperReservation
            && state.seekDrainPending
            && state.activeToken == nil
            && state.awaitingUpdateToken == nil
        )
      let overlapsPriorEpisode = overlapsWrapperEpisode
        || overlapsExternalEpisode
        || state.seekEndedAwaitingPoint
      if let activeFrameRequestID = state.activeFrameRequestID {
        /* The seek start is the causal boundary. If it retires an active ID
         * before cancellation or an exact terminal reservation, a later old
         * result cannot gain Player outcome authority. An earlier reserved
         * result already carries native terminal authority. An ID whose native
         * cancellation returned false is commit-owned, not active here, so its
         * sole exact terminal remains authoritative without rewriting the
         * newer seek timeline. */
        state.retiredFrameRequestIDs.insert(activeFrameRequestID)
        state.activeFrameRequestID = nil
        state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
        state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
        state.frameQuarantined = true
      }
      state.seekDrainPending = true
      state.seekEndedAwaitingPoint = false
      // `vlc_player_UpdateTimerSeekState()` reports every new target, while
      // timer.c stores only `source->seeking: bool`. If another target starts
      // before discontinuity, the starts form one episode with one untagged
      // NULL/end callback. Retire the older wrapper token, but mark the latest
      // ambiguous below: the first discontinuity can still have been produced
      // by an earlier input control already executing in the demuxer.
      if let supersededActiveToken = state.activeToken {
        state.cancelledTokens.remove(supersededActiveToken)
        state.overlappedTokens.remove(supersededActiveToken)
      }
      if let stagedToken {
        state.stagedTokens.removeFirst()
        state.stagedFrameGenerations.removeValue(forKey: stagedToken)
        if isCausallyAttributed {
          state.causallyStartedTokens.insert(stagedToken)
        }
        if overlapsPriorEpisode {
          state.overlappedTokens.insert(stagedToken)
        } else {
          // `stageCommand()` marks a later reservation provisionally while
          // an older command is still draining. If that older episode has
          // produced its end and watched point before this start arrives,
          // the two episodes are causally separated and this token is no
          // longer ambiguous. Leaving the provisional marker behind would
          // discard a valid sequential landing merely because both commands
          // were reserved up front.
          state.overlappedTokens.remove(stagedToken)
        }
      } else {
        // No wrapper reservation owns this callback: it is an external
        // native seek and establishes a fresh invalidation generation now.
        precondition(state.frameGeneration < UInt64.max, "Native frame generation exhausted")
        precondition(state.externalSeekEpoch < UInt64.max, "Native external seek epoch exhausted")
        state.frameGeneration += 1
        state.externalSeekEpoch += 1
        if overlapsPriorEpisode {
          state.externalEpisodeAmbiguous = true
        }
      }
      state.activeToken = stagedToken
      state.activeExternalEpoch = stagedToken == nil && !state.externalEpisodeAmbiguous
        ? state.externalSeekEpoch
        : nil
      if let displacedAwaitingToken = state.awaitingUpdateToken {
        state.cancelledTokens.remove(displacedAwaitingToken)
        state.overlappedTokens.remove(displacedAwaitingToken)
      }
      state.awaitingUpdateToken = nil
      state.awaitingUpdateExternalEpoch = nil
      if stagedToken == nil {
        emissionAuthority.update(
          timelineGeneration: state.timelineGeneration,
          externalEpoch: state.externalSeekEpoch,
          externalDrainPending: true,
          externalOverlapAmbiguous: state.externalEpisodeAmbiguous
        )
      }
      let invalidation = state.frameInvalidationHandler.map {
        (state.frameGeneration, $0)
      }
      let start = NativeSeekStart(
        token: stagedToken,
        externalEpoch: state.externalSeekEpoch
      )
      return (invalidation, start, state.seekStartedHandler)
    }
    // A native seek invalidates every queued wrapper frame command. Deliver
    // the same invalidation to the main-actor queue so an external seek
    // cannot leave Player.pendingFrameSteps waiting for ownership the
    // monitor has already retired.
    if let invalidation = delivery?.0 {
      invalidation.1(invalidation.0)
    }
    if let delivery, let handler = delivery.2 {
      handler(delivery.1)
    }
  }

  func noteSeekEnded(timelineGeneration: UInt64) {
    let delivery = state.withLock { state -> (UInt64, @Sendable (UInt64) -> Void)? in
      guard timelineGeneration == state.timelineGeneration else { return nil }
      state.seekEndedAwaitingPoint = true
      if state.externalEpisodeAmbiguous {
        state.activeToken = nil
        state.awaitingUpdateToken = nil
        state.activeExternalEpoch = nil
        state.awaitingUpdateExternalEpoch = nil
        return nil
      }
      guard let token = state.activeToken else {
        state.awaitingUpdateToken = nil
        state.awaitingUpdateExternalEpoch = state.activeExternalEpoch
        state.activeExternalEpoch = nil
        return nil
      }
      state.activeExternalEpoch = nil
      state.awaitingUpdateExternalEpoch = nil
      state.activeToken = nil
      if state.overlappedTokens.contains(token) {
        // The first discontinuity after overlapping starts may still belong
        // to the earlier input control. Preserve the exact ambiguous token,
        // but never expose its uncorrelated end to the getter fallback.
        state.awaitingUpdateToken = token
        state.cancelledTokens.remove(token)
        state.videoOutputTokens.remove(token)
        return nil
      }
      if state.cancelledTokens.remove(token) != nil {
        state.awaitingUpdateToken = nil
        state.overlappedTokens.remove(token)
        return nil
      }
      state.awaitingUpdateToken = token
      guard let handler = state.seekEndedHandler else { return nil }
      return (token, handler)
    }
    if let delivery {
      delivery.1(delivery.0)
    }
  }

  func resetForTimelineReplacement(
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64
  ) -> (timelineGeneration: UInt64, frameResults: [NativeFrameStepResult]) {
    state.withLock { state in
      /* Attachment detachment has completed before this atomic reset. Drain
       * every exact native terminal reservation admitted before the boundary,
       * then erase commit IDs whose future callbacks can no longer be observed
       * through this attachment. Player resolves the returned proofs before
       * falling back any still-unproven committed waiters. */
      let frameResults = state.frameResultsAwaitingConsumption.values
        .sorted { $0.emissionSequence < $1.emissionSequence }
      state.frameResultsAwaitingConsumption.removeAll(keepingCapacity: true)
      state.commitOwnedFrameRequestIDs.removeAll(keepingCapacity: true)
      precondition(state.timelineGeneration < UInt64.max, "Native seek timeline exhausted")
      state.timelineGeneration += 1
      state.nativeHandleGeneration = nativeHandleGeneration
      state.playbackGeneration = playbackGeneration
      state.reservedTokens.removeAll(keepingCapacity: true)
      state.videoOutputTokens.removeAll(keepingCapacity: true)
      state.expiredVideoOutputToken = nil
      state.postEndVideoClockToken = nil
      state.lateVideoOutputToken = nil
      state.stagedTokens.removeAll(keepingCapacity: true)
      state.stagedFrameGenerations.removeAll(keepingCapacity: true)
      state.cancelledTokens.removeAll(keepingCapacity: true)
      state.causallyStartedTokens.removeAll(keepingCapacity: true)
      state.overlappedTokens.removeAll(keepingCapacity: true)
      state.activeToken = nil
      state.awaitingUpdateToken = nil
      state.seekLandingsAwaitingConsumption.removeAll(keepingCapacity: true)
      state.activeExternalEpoch = nil
      state.awaitingUpdateExternalEpoch = nil
      state.externalEpisodeAmbiguous = false
      precondition(state.frameGeneration < UInt64.max, "Native frame generation exhausted")
      state.frameGeneration += 1
      state.activeFrameRequestID = nil
      state.retiredFrameRequestIDs.removeAll(keepingCapacity: true)
      state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
      state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
      state.frameQuarantined = false
      state.seekDrainPending = false
      state.seekEndedAwaitingPoint = false
      emissionAuthority.update(
        timelineGeneration: state.timelineGeneration,
        externalEpoch: state.externalSeekEpoch,
        externalDrainPending: false,
        externalOverlapAmbiguous: false
      )
      return (state.timelineGeneration, frameResults)
    }
  }

  func currentTimelineGeneration() -> UInt64 {
    state.withLock { $0.timelineGeneration }
  }

  func currentExternalSeekEpoch() -> UInt64 {
    state.withLock { $0.externalSeekEpoch }
  }

  func hasSeekDrainPending() -> Bool {
    state.withLock { $0.seekDrainPending }
  }

  func setHandler(_ handler: (@Sendable (NativeSeekLanding) -> Void)?) {
    state.withLock { $0.handler = handler }
  }

  func setSeekStartedHandler(_ handler: (@Sendable (NativeSeekStart) -> Void)?) {
    state.withLock { $0.seekStartedHandler = handler }
  }

  func setExternalSeekLandingHandler(
    _ handler: (@Sendable (NativeExternalSeekLanding) -> Void)?
  ) {
    state.withLock { $0.externalSeekLandingHandler = handler }
  }

  func setSeekEndedHandler(_ handler: (@Sendable (UInt64) -> Void)?) {
    state.withLock { $0.seekEndedHandler = handler }
  }

  func setSeekDrainAvailabilityHandler(_ handler: (@Sendable () -> Void)?) {
    state.withLock { $0.seekDrainAvailabilityHandler = handler }
  }

  func setFrameHandler(_ handler: (@Sendable (NativeFrameStepResult) -> Void)?) {
    state.withLock { $0.frameHandler = handler }
  }

  func setFrameInvalidationHandler(
    _ handler: (@Sendable (UInt64) -> Void)?
  ) {
    state.withLock { $0.frameInvalidationHandler = handler }
  }

  func setFrameAvailabilityHandler(_ handler: (@Sendable () -> Void)?) {
    state.withLock { $0.frameAvailabilityHandler = handler }
  }
}
