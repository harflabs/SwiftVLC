import Synchronization

extension NativeSeekContext {
  static func retireLateVideoObservation(_ state: inout State) {
    if let token = state.lateVideoOutputToken ?? state.expiredVideoOutputToken {
      state.videoOutputTokens.remove(token)
      state.seekLandingsAwaitingConsumption.removeValue(forKey: token)
    }
    state.lateVideoOutputToken = nil
    state.expiredVideoOutputToken = nil
    state.postEndVideoClockToken = nil
  }

  /// A deadline can release the navigation lease only after native seek-end
  /// and a subsequent clock point. This is not a successful video landing.
  func expireVideoOutputObservation(for token: UInt64) {
    let handlers = state.withLock { state -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) in
      guard state.videoOutputTokens.contains(token) else { return (nil, nil) }
      state.expiredVideoOutputToken = token
      guard
        state.postEndVideoClockToken == token,
        state.awaitingUpdateToken == token,
        state.seekEndedAwaitingPoint,
        !state.overlappedTokens.contains(token),
        !state.externalEpisodeAmbiguous else { return (nil, nil) }
      return Self.releaseExpiredVideoDrain(&state, token: token)
    }
    handlers.0?()
    handlers.1?()
  }

  private static func releaseExpiredVideoDrain(
    _ state: inout State, token: UInt64
  ) -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) {
    state.awaitingUpdateToken = nil
    state.lateVideoOutputToken = token
    state.seekEndedAwaitingPoint = false
    state.seekDrainPending = !state.stagedTokens.isEmpty || state.activeToken != nil
    if let id = state.activeFrameRequestID {
      state.retiredFrameRequestIDs.insert(id)
    }
    state.activeFrameRequestID = nil
    state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
    state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
    state.frameQuarantined = false
    return (
      state.seekDrainPending ? nil : state.seekDrainAvailabilityHandler,
      state.seekDrainPending ? nil : state.frameAvailabilityHandler
    )
  }

  func requireVideoOutput(for token: UInt64) {
    _ = state.withLock { $0.videoOutputTokens.insert(token) }
  }

  func noteTimeUpdated(
    timeMicroseconds: Int64,
    position: Double,
    timelineGeneration: UInt64,
    isVideoOutput: Bool = false,
    frameDurationMicroseconds: Int64 = 0
  ) {
    typealias SeekDelivery = (NativeSeekLanding, @Sendable (NativeSeekLanding) -> Void)
    typealias ExternalDelivery = (
      NativeExternalSeekLanding,
      @Sendable (NativeExternalSeekLanding) -> Void
    )
    typealias Delivery = (
      SeekDelivery?,
      ExternalDelivery?,
      (@Sendable () -> Void)?,
      (@Sendable () -> Void)?
    )
    let delivery = state.withLock { state -> Delivery in
      let hasAuthoritativeTime = timeMicroseconds >= 0
      let hasAuthoritativePosition = position.isFinite && (0.0...1.0).contains(position)
      let timeMilliseconds = hasAuthoritativeTime ? timeMicroseconds / 1000 : nil
      let authoritativePosition = hasAuthoritativePosition ? position : nil
      guard
        timelineGeneration == state.timelineGeneration,
        hasAuthoritativeTime || (state.seekEndedAwaitingPoint && hasAuthoritativePosition)
      else {
        return (nil, nil, nil, nil)
      }
      if
        isVideoOutput, let lateToken = state.lateVideoOutputToken,
        state.awaitingUpdateToken == nil, state.activeToken == nil {
        state.awaitingUpdateToken = lateToken
        state.lateVideoOutputToken = nil
      }
      if
        let token = state.awaitingUpdateToken ?? state.activeToken,
        state.videoOutputTokens.contains(token), !isVideoOutput {
        // Remember completion separately from output evidence. A clock can
        // release an expired navigation lease, but can never settle video.
        guard
          state.seekEndedAwaitingPoint,
          !state.overlappedTokens.contains(token),
          !state.externalEpisodeAmbiguous else { return (nil, nil, nil, nil) }
        state.postEndVideoClockToken = token
        guard state.expiredVideoOutputToken == token else { return (nil, nil, nil, nil) }
        let handlers = Self.releaseExpiredVideoDrain(&state, token: token)
        return (nil, nil, handlers.0, handlers.1)
      }
      if
        state.seekEndedAwaitingPoint,
        state.externalEpisodeAmbiguous {
        // An end after overlapping tokenless starts cannot identify which
        // episode produced this point. Retain drain ownership until reset.
        return (nil, nil, nil, nil)
      }
      if
        state.seekEndedAwaitingPoint,
        let awaitingUpdateToken = state.awaitingUpdateToken,
        state.overlappedTokens.contains(awaitingUpdateToken) {
        // VLC supplies no request ID on seek end/update. For overlapping
        // controls this point may be the displaced request's landing, so it
        // cannot settle the latest token or release frame ownership.
        return (nil, nil, nil, nil)
      }
      let availabilityHandler: (@Sendable () -> Void)?
      let seekDrainAvailabilityHandler: (@Sendable () -> Void)?
      let externalLandingSequence: UInt64?
      if state.seekEndedAwaitingPoint {
        state.seekEndedAwaitingPoint = false
        state.seekDrainPending = !state.stagedTokens.isEmpty || state.activeToken != nil
        if let activeFrameRequestID = state.activeFrameRequestID {
          state.retiredFrameRequestIDs.insert(activeFrameRequestID)
        }
        state.activeFrameRequestID = nil
        state.frameDispatchRetiredSnapshot.removeAll(keepingCapacity: true)
        state.frameRetryBlockerIDs.removeAll(keepingCapacity: true)
        state.frameQuarantined = false
        availabilityHandler = state.seekDrainPending ? nil : state.frameAvailabilityHandler
        seekDrainAvailabilityHandler = state.seekDrainPending
          ? nil
          : state.seekDrainAvailabilityHandler
        if state.awaitingUpdateExternalEpoch != nil {
          externalLandingSequence = emissionAuthority.finishExternalDrainAndAdvance(
            timelineGeneration: state.timelineGeneration,
            playbackGeneration: state.playbackGeneration,
            externalEpoch: state.externalSeekEpoch,
            timeMilliseconds: timeMilliseconds,
            position: authoritativePosition
          )
        } else {
          externalLandingSequence = nil
        }
      } else {
        availabilityHandler = nil
        seekDrainAvailabilityHandler = nil
        externalLandingSequence = nil
      }
      if let token = state.awaitingUpdateToken {
        let emissionSequence = emissionAuthority.recordTimelineAndAdvance(
          timelineGeneration: state.timelineGeneration,
          playbackGeneration: state.playbackGeneration,
          timeMilliseconds: timeMilliseconds,
          position: authoritativePosition
        )
        state.awaitingUpdateToken = nil
        state.awaitingUpdateExternalEpoch = nil
        state.overlappedTokens.remove(token)
        let landing = NativeSeekLanding(
          token: token,
          timeMilliseconds: timeMilliseconds ?? -1,
          position: position,
          emissionSequence: emissionSequence,
          isVideoOutput: isVideoOutput,
          frameDurationMicroseconds: frameDurationMicroseconds
        )
        state.videoOutputTokens.remove(token)
        let reservedLanding: NativeSeekLanding
        if let existing = state.seekLandingsAwaitingConsumption[token] {
          reservedLanding = existing
        } else {
          state.seekLandingsAwaitingConsumption[token] = landing
          reservedLanding = landing
        }
        let seekDelivery = state.handler.map { (reservedLanding, $0) }
        return (seekDelivery, nil, seekDrainAvailabilityHandler, availabilityHandler)
      }
      if
        let externalEpoch = state.awaitingUpdateExternalEpoch,
        let handler = state.externalSeekLandingHandler {
        state.awaitingUpdateExternalEpoch = nil
        return (
          nil,
          (NativeExternalSeekLanding(
            timelineGeneration: timelineGeneration,
            nativeHandleGeneration: state.nativeHandleGeneration,
            playbackGeneration: state.playbackGeneration,
            externalEpoch: externalEpoch,
            timeMilliseconds: timeMilliseconds ?? -1,
            position: position,
            emissionSequence: externalLandingSequence
              ?? emissionAuthority.advanceTimelineEmissionSequence()
          ), handler),
          seekDrainAvailabilityHandler,
          availabilityHandler
        )
      }
      state.awaitingUpdateExternalEpoch = nil
      return (nil, nil, seekDrainAvailabilityHandler, availabilityHandler)
    }
    if let seek = delivery.0 {
      seek.1(seek.0)
    }
    if let external = delivery.1 {
      external.1(external.0)
    }
    delivery.2?()
    delivery.3?()
  }
}
