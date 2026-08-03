import Foundation

struct PlaybackRendererHealthSample: Sendable, Equatable {
  var playbackGeneration: UInt64?
  var voutGeneration: UInt64?
  var decodedFrames: UInt64 = 0
  var enqueuedFrames: UInt64 = 0
  var presentedFrames: UInt64 = 0
  var droppedFrames: UInt64 = 0
  var rebuilds: UInt64 = 0
  var flushes: UInt64 = 0
  var backpressureDrops: UInt64 = 0
  var replacements: UInt64 = 0
  var recoveryRetries: UInt64 = 0
  var recoveryFailures: UInt64 = 0
  var lastDecodedAt: ContinuousClock.Instant?
  var lastEnqueuedAt: ContinuousClock.Instant?
  var lastPresentedAt: ContinuousClock.Instant?
  var status: PlaybackRendererStatus = .unavailable
}

struct PlaybackHealthMonitoringState {
  var generation: UInt64 = 0
  var startedAt = ContinuousClock.now
  var rendererBaseline: PlaybackRendererHealthSample?
  var previousCounters = PlaybackHealthCounters()
  var lastSourceProgressAt = ContinuousClock.now
  var lastDecodedProgressAt = ContinuousClock.now
  var lastAudioDecodedProgressAt = ContinuousClock.now
  var lastPresentedProgressAt = ContinuousClock.now
  var lastAudioProgressAt = ContinuousClock.now
  var activePlaybackBeganAt = ContinuousClock.now
  var firstDecodedEmitted = false
  var firstPresentedEmitted = false
  var pendingWaitingReason: PlaybackWaitingReason?
  var pendingWaitingBeganAt: ContinuousClock.Instant?
  var pendingPresentedBaseline: UInt64 = 0
  var pendingAudioBaseline: UInt64 = 0
  var lastStallReason: PlaybackStallReason?
  var activeStallReason: PlaybackStallReason?
  var lastStalledAt: Duration?
  var lastRecoveredAt: Duration?
  var observedRendererFlushes: UInt64 = 0

  mutating func reset(
    generation: UInt64,
    rendererBaseline: PlaybackRendererHealthSample?
  ) {
    let now = ContinuousClock.now
    self.generation = generation
    startedAt = now
    self.rendererBaseline = rendererBaseline
    previousCounters = PlaybackHealthCounters()
    lastSourceProgressAt = now
    lastDecodedProgressAt = now
    lastAudioDecodedProgressAt = now
    lastPresentedProgressAt = now
    lastAudioProgressAt = now
    activePlaybackBeganAt = now
    firstDecodedEmitted = false
    firstPresentedEmitted = false
    pendingWaitingReason = nil
    pendingWaitingBeganAt = nil
    pendingPresentedBaseline = 0
    pendingAudioBaseline = 0
    lastStallReason = nil
    activeStallReason = nil
    lastStalledAt = nil
    lastRecoveredAt = nil
    observedRendererFlushes = 0
  }
}

/// Playback-health publication and the low-rate classifier that drives it.
extension Player {
  /// How often cumulative pipeline counters are sampled.
  ///
  /// This is deliberately independent of source cadence: 24, 60, and 120 fps
  /// all cost four public samples per second.
  public nonisolated static var playbackHealthSamplingInterval: Duration {
    .milliseconds(250)
  }

  /// A pipeline stage becomes stalled only after this much time without the
  /// progress expected from the stages before it.
  public nonisolated static var playbackHealthStallThreshold: Duration {
    .seconds(2)
  }

  /// Current playback-health snapshots, replaying the latest value to a late
  /// subscriber. The stream is bounded because each value supersedes the prior
  /// point-in-time sample.
  public nonisolated var playbackHealthSnapshots: AsyncStream<PlaybackHealthSnapshot> {
    playbackHealthSnapshotBridge.subscribeReplayingLatest(policy: .newest(1))
  }

  /// Semantic playback-health transitions.
  ///
  /// The latest transition is replayed. The attached snapshot retains the last
  /// stall reason and both stall/recovery timestamps, so a subscriber arriving
  /// after recovery can still reconstruct the pair. The live buffer is
  /// unbounded because first-frame, stall, recovery, and terminal transitions
  /// must never be evicted by consumer lag.
  public nonisolated var playbackHealthEvents: AsyncStream<PlaybackHealthEvent> {
    playbackHealthEventBridge.subscribeReplayingLatest(policy: .unbounded)
  }

  func resetPlaybackHealth() {
    playbackHealthEventBridge.clearReplay()
    #if os(iOS) || os(macOS)
    directPiPVideoCallbackRegistration?.beginPlaybackGeneration(sessionGeneration)
    #endif
    let renderer = capturePlaybackRendererHealth()
    playbackHealthMonitoringState.reset(
      generation: sessionGeneration,
      rendererBaseline: renderer
    )
    publishPlaybackHealth(
      state: .idle,
      counters: PlaybackHealthCounters(),
      renderer: renderer,
      now: ContinuousClock.now
    )
  }

  func markPlaybackHealthSeek() {
    markPlaybackHealthWaiting(.seeking)
  }

  func markPlaybackHealthAdaptiveSwitch() {
    guard state == .playing, playbackHealthMonitoringState.firstPresentedEmitted else {
      return
    }
    markPlaybackHealthWaiting(.adaptiveSwitch)
  }

  private func markPlaybackHealthWaiting(_ reason: PlaybackWaitingReason) {
    let now = ContinuousClock.now
    let renderer = capturePlaybackRendererHealth()
    let counters = makePlaybackHealthCounters(renderer: renderer)
    updatePlaybackHealthProgress(counters: counters, renderer: renderer, now: now)
    guard counters.rendererRecoveryFailures == 0 else {
      clearPlaybackHealthWaiting()
      publishPlaybackHealth(
        state: .failed(.renderer),
        counters: counters,
        renderer: renderer,
        now: now
      )
      reconcilePlaybackHealthSamplingTask()
      return
    }
    playbackHealthMonitoringState.pendingWaitingReason = reason
    playbackHealthMonitoringState.pendingWaitingBeganAt = now
    playbackHealthMonitoringState.pendingPresentedBaseline = counters.presentedVideoFrames
    playbackHealthMonitoringState.pendingAudioBaseline = counters.playedAudioBuffers
    // Publish from the exact counters used as the baseline. Sampling again
    // here would let progress that predates the command clear the wait before
    // any subscriber can observe it.
    publishPlaybackHealth(
      state: .waiting(reason),
      counters: counters,
      renderer: renderer,
      now: now
    )
    reconcilePlaybackHealthSamplingTask()
  }

  /// Grants a fresh progress window when intentional inactivity ends.
  /// Generation clocks remain generation-relative for event timestamps; only
  /// the stall clocks are rearmed.
  func rearmPlaybackHealthAfterEnteringPlaying() {
    let now = ContinuousClock.now
    playbackHealthMonitoringState.lastSourceProgressAt = now
    playbackHealthMonitoringState.lastDecodedProgressAt = now
    playbackHealthMonitoringState.lastAudioDecodedProgressAt = now
    playbackHealthMonitoringState.lastPresentedProgressAt = now
    playbackHealthMonitoringState.lastAudioProgressAt = now
    playbackHealthMonitoringState.activePlaybackBeganAt = now
  }

  func reconcilePlaybackHealthSamplingTask() {
    let needsSampling = state.isActive
      || playbackHealthMonitoringState.pendingWaitingReason != nil
    if !needsSampling {
      playbackHealthSamplingTask?.cancel()
      playbackHealthSamplingTask = nil
      return
    }
    guard playbackHealthSamplingTask == nil else { return }
    playbackHealthSamplingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.playbackHealthSamplingInterval)
        } catch {
          return
        }
        guard let self else { return }
        samplePlaybackHealth()
        let keepSampling = state.isActive
          || playbackHealthMonitoringState.pendingWaitingReason != nil
        guard keepSampling else {
          playbackHealthSamplingTask = nil
          return
        }
      }
    }
  }

  func samplePlaybackHealth() {
    if playbackHealthMonitoringState.generation != sessionGeneration {
      // Recast and externally adopted generations can advance without a media
      // reset. Use the full boundary operation so replay and direct-renderer
      // telemetry cannot remain stamped with the predecessor generation.
      resetPlaybackHealth()
    }

    let now = ContinuousClock.now
    let renderer = capturePlaybackRendererHealth()
    let counters = makePlaybackHealthCounters(renderer: renderer)
    updatePlaybackHealthProgress(counters: counters, renderer: renderer, now: now)
    let classified = classifyPlaybackHealth(counters: counters, renderer: renderer, now: now)
    publishPlaybackHealth(state: classified, counters: counters, renderer: renderer, now: now)
  }

  private func classifyPlaybackHealth(
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample?,
    now: ContinuousClock.Instant
  ) -> PlaybackHealthState {
    switch state {
    case .idle, .stopped, .stopping:
      clearPlaybackHealthWaiting()
      return .idle
    case .paused:
      if counters.rendererRecoveryFailures > 0 {
        clearPlaybackHealthWaiting()
        return .failed(.renderer)
      }
      if renderer?.status == .recovering {
        return .stalled(.rendererRecovery)
      }
      clearPlaybackHealthWaiting()
      return .paused
    case .error:
      clearPlaybackHealthWaiting()
      return .failed(.player)
    case .opening:
      return .waiting(.opening)
    case .buffering:
      return .waiting(.buffering)
    case .playing:
      break
    }

    if counters.rendererRecoveryFailures > 0 {
      return .failed(.renderer)
    }
    if renderer?.status == .recovering {
      return .stalled(.rendererRecovery)
    }

    let hasVideo = activeVideoOutputs > 0
      || videoTracks.contains(where: \.isSelected)
      || counters.decodedVideoFrames > 0
      || counters.presentedVideoFrames > 0
    let hasAudio = audioTracks.contains(where: \.isSelected)
      || counters.decodedAudioFrames > 0
      || counters.playedAudioBuffers > 0

    if let waiting = playbackHealthMonitoringState.pendingWaitingReason {
      let progressed = if hasVideo {
        counters.presentedVideoFrames
          > playbackHealthMonitoringState.pendingPresentedBaseline
      } else {
        counters.playedAudioBuffers > playbackHealthMonitoringState.pendingAudioBaseline
      }
      if progressed {
        clearPlaybackHealthWaiting()
      } else if
        let began = playbackHealthMonitoringState.pendingWaitingBeganAt,
        began.duration(to: now) < Self.playbackHealthStallThreshold {
        return .waiting(waiting)
      }
    }

    if hasVideo {
      if
        counters.presentedVideoFrames == 0,
        playbackHealthMonitoringState.activePlaybackBeganAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .waiting(.firstFrame)
      }
      let videoIsProgressing = playbackHealthMonitoringState.lastPresentedProgressAt
        .duration(to: now) < Self.playbackHealthStallThreshold
      let audioIsProgressing = playbackHealthMonitoringState.lastAudioProgressAt
        .duration(to: now) < Self.playbackHealthStallThreshold
      if
        hasAudio,
        counters.playedAudioBuffers == 0,
        playbackHealthMonitoringState.activePlaybackBeganAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .waiting(.firstFrame)
      }
      if videoIsProgressing, !hasAudio || audioIsProgressing {
        return .healthy(contentKind(hasVideo: true, hasAudio: hasAudio))
      }
      if videoIsProgressing, hasAudio {
        if
          playbackHealthMonitoringState.lastAudioDecodedProgressAt.duration(to: now)
          < Self.playbackHealthStallThreshold {
          return .stalled(.audioOutput)
        }
        // Video presentation proves the shared source is still progressing;
        // the missing audio progress is therefore downstream of the source.
        return .stalled(.decoder)
      }
      if
        playbackHealthMonitoringState.lastDecodedProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.display)
      }
      if
        playbackHealthMonitoringState.lastSourceProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.decoder)
      }
      return .stalled(.source)
    }

    if hasAudio {
      if
        counters.playedAudioBuffers == 0,
        playbackHealthMonitoringState.activePlaybackBeganAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .waiting(.firstFrame)
      }
      if
        playbackHealthMonitoringState.lastAudioProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .healthy(.audioOnly)
      }
      if
        playbackHealthMonitoringState.lastAudioDecodedProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.audioOutput)
      }
      if
        playbackHealthMonitoringState.lastSourceProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.decoder)
      }
      return .stalled(.source)
    }

    if
      playbackHealthMonitoringState.activePlaybackBeganAt.duration(to: now)
      < Self.playbackHealthStallThreshold {
      return .waiting(.firstFrame)
    }
    return .stalled(.source)
  }

  private func clearPlaybackHealthWaiting() {
    playbackHealthMonitoringState.pendingWaitingReason = nil
    playbackHealthMonitoringState.pendingWaitingBeganAt = nil
    playbackHealthMonitoringState.pendingPresentedBaseline = 0
    playbackHealthMonitoringState.pendingAudioBaseline = 0
  }

  private func contentKind(hasVideo: Bool, hasAudio: Bool) -> PlaybackContentKind {
    switch (hasVideo, hasAudio) {
    case (true, true): .audiovisual
    case (true, false): .videoOnly
    case (false, true), (false, false): .audioOnly
    }
  }

  private func updatePlaybackHealthProgress(
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample?,
    now: ContinuousClock.Instant
  ) {
    let previous = playbackHealthMonitoringState.previousCounters
    if
      counters.sourceReadBytes > previous.sourceReadBytes
      || counters.demuxReadBytes > previous.demuxReadBytes {
      playbackHealthMonitoringState.lastSourceProgressAt = now
    }
    if counters.decodedVideoFrames > previous.decodedVideoFrames {
      playbackHealthMonitoringState.lastDecodedProgressAt = renderer?.lastDecodedAt ?? now
    }
    if counters.decodedAudioFrames > previous.decodedAudioFrames {
      playbackHealthMonitoringState.lastAudioDecodedProgressAt = now
    }
    if counters.presentedVideoFrames > previous.presentedVideoFrames {
      playbackHealthMonitoringState.lastPresentedProgressAt = renderer?.lastPresentedAt ?? now
    }
    if counters.playedAudioBuffers > previous.playedAudioBuffers {
      playbackHealthMonitoringState.lastAudioProgressAt = now
    }
    playbackHealthMonitoringState.previousCounters = counters
  }

  private func makePlaybackHealthCounters(
    renderer: PlaybackRendererHealthSample?
  ) -> PlaybackHealthCounters {
    let stats = statistics
    let direct = renderer.map(rendererDelta) ?? PlaybackRendererHealthSample()
    return PlaybackHealthCounters(
      sourceReadBytes: stats?.readBytes ?? 0,
      demuxReadBytes: stats?.demuxReadBytes ?? 0,
      decodedVideoFrames: max(stats?.decodedVideo ?? 0, direct.decodedFrames),
      decodedAudioFrames: stats?.decodedAudio ?? 0,
      enqueuedVideoFrames: direct.enqueuedFrames,
      presentedVideoFrames: max(stats?.displayedPictures ?? 0, direct.presentedFrames),
      playedAudioBuffers: stats?.playedAudioBuffers ?? 0,
      droppedVideoFrames: addingWithoutOverflow(stats?.lostPictures ?? 0, direct.droppedFrames),
      lateVideoFrames: stats?.latePictures ?? 0,
      rendererRebuilds: direct.rebuilds,
      rendererFlushes: direct.flushes,
      rendererBackpressureDrops: direct.backpressureDrops,
      rendererFrameReplacements: direct.replacements,
      rendererRecoveryRetries: direct.recoveryRetries,
      rendererRecoveryFailures: direct.recoveryFailures
    )
  }

  private func rendererDelta(
    _ current: PlaybackRendererHealthSample
  ) -> PlaybackRendererHealthSample {
    guard let baseline = playbackHealthMonitoringState.rendererBaseline else {
      return current
    }
    var delta = current
    delta.decodedFrames = subtractingWithoutUnderflow(current.decodedFrames, baseline.decodedFrames)
    delta.enqueuedFrames = subtractingWithoutUnderflow(current.enqueuedFrames, baseline.enqueuedFrames)
    delta.presentedFrames = subtractingWithoutUnderflow(current.presentedFrames, baseline.presentedFrames)
    delta.droppedFrames = subtractingWithoutUnderflow(current.droppedFrames, baseline.droppedFrames)
    delta.rebuilds = subtractingWithoutUnderflow(current.rebuilds, baseline.rebuilds)
    delta.flushes = subtractingWithoutUnderflow(current.flushes, baseline.flushes)
    delta.backpressureDrops = subtractingWithoutUnderflow(
      current.backpressureDrops,
      baseline.backpressureDrops
    )
    delta.replacements = subtractingWithoutUnderflow(current.replacements, baseline.replacements)
    delta.recoveryRetries = subtractingWithoutUnderflow(
      current.recoveryRetries,
      baseline.recoveryRetries
    )
    delta.recoveryFailures = subtractingWithoutUnderflow(
      current.recoveryFailures,
      baseline.recoveryFailures
    )
    return delta
  }

  private func publishPlaybackHealth(
    state newState: PlaybackHealthState,
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample?,
    now: ContinuousClock.Instant
  ) {
    let previousState = playbackHealth.state
    var eventKinds: [PlaybackHealthEventKind] = []

    let completedUnobservedRendererRecovery = counters.rendererFlushes
      > playbackHealthMonitoringState.observedRendererFlushes
      && renderer?.status == .rendering
      && counters.rendererRecoveryFailures == 0
    if completedUnobservedRendererRecovery {
      playbackHealthMonitoringState.lastStallReason = .rendererRecovery
      playbackHealthMonitoringState.lastStalledAt = elapsed(to: renderer?.lastEnqueuedAt)
        ?? elapsed(to: now)
      playbackHealthMonitoringState.lastRecoveredAt = elapsed(to: renderer?.lastPresentedAt)
        ?? elapsed(to: now)
      eventKinds.append(.stalled(.rendererRecovery))
      eventKinds.append(.recovered(from: .rendererRecovery))
    }
    playbackHealthMonitoringState.observedRendererFlushes = counters.rendererFlushes

    if
      !playbackHealthMonitoringState.firstDecodedEmitted,
      counters.decodedVideoFrames > 0 {
      playbackHealthMonitoringState.firstDecodedEmitted = true
      eventKinds.append(.firstDecodedFrame)
    }
    if
      !playbackHealthMonitoringState.firstPresentedEmitted,
      counters.presentedVideoFrames > 0 {
      playbackHealthMonitoringState.firstPresentedEmitted = true
      eventKinds.append(.firstPresentedFrame)
    }

    if
      case .stalled(let reason) = newState,
      previousState != newState {
      playbackHealthMonitoringState.lastStallReason = reason
      playbackHealthMonitoringState.activeStallReason = reason
      playbackHealthMonitoringState.lastStalledAt = elapsed(to: now)
      eventKinds.append(.stalled(reason))
    } else if
      case .waiting(let reason) = newState,
      previousState != newState {
      eventKinds.append(.waiting(reason))
    }

    if
      let reason = playbackHealthMonitoringState.activeStallReason,
      case .healthy = newState {
      playbackHealthMonitoringState.lastRecoveredAt = elapsed(to: now)
      playbackHealthMonitoringState.activeStallReason = nil
      eventKinds.append(.recovered(from: reason))
    } else if
      !completedUnobservedRendererRecovery,
      previousState == .stalled(.rendererRecovery),
      renderer?.status == .rendering {
      playbackHealthMonitoringState.lastRecoveredAt = elapsed(to: renderer?.lastPresentedAt)
        ?? elapsed(to: now)
      playbackHealthMonitoringState.activeStallReason = nil
      eventKinds.append(.recovered(from: .rendererRecovery))
    }
    if
      case .failed(let failure) = newState,
      previousState != newState {
      eventKinds.append(.terminalFailure(failure))
    }

    let snapshot = PlaybackHealthSnapshot(
      generation: PlaybackGeneration(sessionGeneration),
      state: newState,
      revision: playbackHealth.revision &+ 1,
      lastDecodedAt: elapsed(to: renderer?.lastDecodedAt)
        ?? (counters.decodedVideoFrames > 0 ? elapsed(to: playbackHealthMonitoringState.lastDecodedProgressAt) : nil),
      lastEnqueuedAt: elapsed(to: renderer?.lastEnqueuedAt),
      lastPresentedAt: elapsed(to: renderer?.lastPresentedAt)
        ?? (counters.presentedVideoFrames > 0 ? elapsed(to: playbackHealthMonitoringState.lastPresentedProgressAt) : nil),
      rendererStatus: renderer?.status ?? .unavailable,
      voutGeneration: renderer?.voutGeneration,
      counters: counters,
      lastStallReason: playbackHealthMonitoringState.lastStallReason,
      lastStalledAt: playbackHealthMonitoringState.lastStalledAt,
      lastRecoveredAt: playbackHealthMonitoringState.lastRecoveredAt
    )
    playbackHealth = snapshot
    playbackHealthSnapshotBridge.broadcast(snapshot)
    for kind in eventKinds {
      playbackHealthEventBridge.broadcast(PlaybackHealthEvent(kind: kind, snapshot: snapshot))
    }
  }

  private func elapsed(to instant: ContinuousClock.Instant?) -> Duration? {
    guard let instant, instant >= playbackHealthMonitoringState.startedAt else { return nil }
    return playbackHealthMonitoringState.startedAt.duration(to: instant)
  }

  private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
  }

  private func subtractingWithoutUnderflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    lhs >= rhs ? lhs - rhs : 0
  }

  /// `Track` identity intentionally compares only IDs. Health needs to notice
  /// adaptive metadata changes that retain an ES ID, so compare the complete
  /// video description in a stable ID order instead.
  static func playbackHealthVideoTracksDiffer(_ lhs: [Track], _ rhs: [Track]) -> Bool {
    guard lhs.count == rhs.count else { return true }
    let left = lhs.sorted { $0.id < $1.id }
    let right = rhs.sorted { $0.id < $1.id }
    return zip(left, right).contains { left, right in
      left.id != right.id
        || left.type != right.type
        || left.name != right.name
        || left.codec != right.codec
        || left.language != right.language
        || left.trackDescription != right.trackDescription
        || left.isSelected != right.isSelected
        || left.bitrate != right.bitrate
        || left.width != right.width
        || left.height != right.height
        || left.frameRate != right.frameRate
        || left.frameRateRatio != right.frameRateRatio
    }
  }

  private func capturePlaybackRendererHealth() -> PlaybackRendererHealthSample? {
    #if os(iOS) || os(macOS)
    guard let telemetry = directPiPVideoCallbackRegistration?.telemetrySnapshot else {
      return nil
    }
    guard telemetry.playbackGeneration == sessionGeneration else { return nil }
    let rendererStatus: PlaybackRendererStatus = switch telemetry.status {
    case .idle: .idle
    case .rendering: .rendering
    case .backpressured: .backpressured
    case .recovering: .recovering
    case .failed: .failed
    }
    return PlaybackRendererHealthSample(
      playbackGeneration: telemetry.playbackGeneration,
      voutGeneration: telemetry.voutGeneration,
      decodedFrames: telemetry.decodedFrameCount,
      enqueuedFrames: telemetry.enqueuedFrameCount,
      presentedFrames: telemetry.presentedFrameCount,
      droppedFrames: telemetry.droppedFrameCount,
      rebuilds: telemetry.voutTransitionCount,
      flushes: telemetry.flushCount,
      backpressureDrops: telemetry.backpressureDropCount,
      replacements: telemetry.replacementCount,
      recoveryRetries: telemetry.flushRecoveryRetryCount,
      recoveryFailures: telemetry.flushRecoveryFailureCount,
      lastDecodedAt: telemetry.lastDecodedAt,
      lastEnqueuedAt: telemetry.lastEnqueuedAt,
      lastPresentedAt: telemetry.lastPresentedAt,
      status: rendererStatus
    )
    #else
    return nil
    #endif
  }

  #if DEBUG
  func _applyPlaybackHealthSampleForTesting(
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample? = nil,
    now: ContinuousClock.Instant = .now
  ) {
    updatePlaybackHealthProgress(counters: counters, renderer: renderer, now: now)
    let classified = classifyPlaybackHealth(counters: counters, renderer: renderer, now: now)
    publishPlaybackHealth(state: classified, counters: counters, renderer: renderer, now: now)
  }
  #endif
}
