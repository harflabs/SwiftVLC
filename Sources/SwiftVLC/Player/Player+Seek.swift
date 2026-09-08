import CLibVLC

#if DEBUG
struct PlayerSeekTestOverrides {
  var hasSelectedVideo: Bool?
  var supportsPausedSeekOutputClock: Bool?
  var setTime: ((Int64, Bool) -> Int32)?
  var jumpTime: ((Int64) -> Int32)?
  var setPosition: ((Double, Bool) -> Int32)?
  var readBaseline: (() -> (timeMilliseconds: Int64, position: Double))?
  var readLanding: (() -> (timeMilliseconds: Int64, position: Double))?
  var nextFrame: ((UInt64) -> NativeFrameRequestDispatch)?
  var cancelNextFrame: ((UInt64) -> Bool)?
}
#endif

/// Seeking: strict absolute/relative seeks for VOD scrubbers, lenient
/// best-effort seeks for live and unknown-duration media, and
/// frame-by-frame stepping.
extension Player {
  struct PendingSeekSettlement {
    let playbackGeneration: UInt64
    var timelineRevision: UInt64?
    let nativeSeekToken: UInt64
    let resolver: SeekOutcomeResolver
    var baselineTimeMilliseconds: Int64?
    var baselinePosition: Double?
    var requestedTimeMilliseconds: Int64?
    var requestedPosition: Double?
    var firstPostEndTimeMilliseconds: Int64?
    var firstPostEndPosition: Double?
    var allowsPausedFallback: Bool
    var deadlinePhase: SeekSettlementDeadlinePhase
    var timeoutTask: Task<Void, Never>?
    var pollingTask: Task<Void, Never>?
  }

  enum NativeSeekOperation {
    case time(milliseconds: Int64, fast: Bool)
    case position(Double, fast: Bool)
    case relative(milliseconds: Int64)
    /// One or more strict `seek(by:)` commands anchored to the observable
    /// timeline at acceptance. Keeping the offsets as intent (rather than
    /// replacing them with identical absolute snapshots) lets a rapid skip
    /// burst aggregate while it waits behind the sole native seek owner.
    case strictRelative(StrictRelativeSeekIntent)
    /// A queued absolute/fractional intent followed by one or more relative
    /// commands. It is deliberately unresolved until native dispatch so the
    /// duration used for fractional conversion and final clamping is current.
    case composed(DeferredSeekComposition)
  }

  struct StrictRelativeSeekIntent {
    let baseMilliseconds: Int64
    var offsetsMilliseconds: [Int64]
    var fast: Bool
  }

  enum DeferredSeekCompositionBase {
    case absoluteMilliseconds(Int64)
    case position(Double)
    case invalid
  }

  struct DeferredSeekComposition {
    let base: DeferredSeekCompositionBase
    var relativeOffsetsMilliseconds: [Int64]
  }

  enum SeekOptimisticPublication {
    case time(milliseconds: Int64)
    case position(Double, timeMilliseconds: Int64?)
    case revisionOnly
  }

  enum SeekSettlementDeadlinePhase: Equatable {
    case queued
    case dispatched
  }

  struct NativeSeekCommand {
    let nativeSeekToken: UInt64
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
    let externalEpoch: UInt64
    var timelineRevision: UInt64?
    var dispatchEmissionSequence: UInt64?
    var operation: NativeSeekOperation
    var evidence: SeekSettlementEvidence
    var publication: SeekOptimisticPublication
    let resolver: SeekOutcomeResolver
  }

  struct ActiveNativeSeek {
    var command: NativeSeekCommand
    var firstPostEndTimeMilliseconds: Int64?
    var firstPostEndPosition: Double?
    var allowsPausedFallback: Bool
    var isTombstoned: Bool
    var deadlineTask: Task<Void, Never>?
    var pollingTask: Task<Void, Never>?
  }

  struct QuarantinedSeekTimeline {
    let nativeSeekToken: UInt64
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
    var time: Duration?
    var timeEmissionSequence: UInt64?
    var position: Double?
    var positionEmissionSequence: UInt64?
  }

  enum PendingFrameStepPhase: Equatable {
    case awaitingPause
    case awaitingFrame
  }

  struct PendingFrameStep {
    let requestToken: UInt64
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
    let nativeFrameGeneration: UInt64
    let resolver: FrameStepOutcomeResolver
    var phase: PendingFrameStepPhase
    var didDispatchNativeRequest: Bool
    var nativeRequestInFlight: Bool
    var timeoutTask: Task<Void, Never>?
  }

  /// A cancellation raced a strict native request whose output commitment
  /// may already own the terminal. It no longer blocks the wrapper FIFO, but
  /// its resolver remains pending until the sole ID-matched event arrives.
  struct CommittedFrameStepAwaitingTerminal {
    var frame: PendingFrameStep
    let fallbackOutcome: FrameStepOutcome
    let allowsTimelineMutation: Bool
  }

  struct SeekSettlementEvidence {
    let baselineTimeMilliseconds: Int64?
    let baselinePosition: Double?
    let requestedTimeMilliseconds: Int64?
    let requestedPosition: Double?
  }

  #if DEBUG
  var _nativeSetTimeOverrideForTesting: ((Int64, Bool) -> Int32)? {
    get { _seekOverridesForTesting.setTime }
    set { _seekOverridesForTesting.setTime = newValue }
  }

  var _nativeJumpTimeOverrideForTesting: ((Int64) -> Int32)? {
    get { _seekOverridesForTesting.jumpTime }
    set { _seekOverridesForTesting.jumpTime = newValue }
  }

  var _nativeSetPositionOverrideForTesting: ((Double, Bool) -> Int32)? {
    get { _seekOverridesForTesting.setPosition }
    set { _seekOverridesForTesting.setPosition = newValue }
  }

  var _nativeSeekLandingOverrideForTesting:
    (() -> (timeMilliseconds: Int64, position: Double))? {
    get { _seekOverridesForTesting.readLanding }
    set { _seekOverridesForTesting.readLanding = newValue }
  }

  var _nativeSeekBaselineOverrideForTesting:
    (() -> (timeMilliseconds: Int64, position: Double))? {
    get { _seekOverridesForTesting.readBaseline }
    set { _seekOverridesForTesting.readBaseline = newValue }
  }

  var _nativeNextFrameOverrideForTesting:
    ((UInt64) -> NativeFrameRequestDispatch)? {
    get { _seekOverridesForTesting.nextFrame }
    set { _seekOverridesForTesting.nextFrame = newValue }
  }

  var _nativeCancelNextFrameOverrideForTesting: ((UInt64) -> Bool)? {
    get { _seekOverridesForTesting.cancelNextFrame }
    set { _seekOverridesForTesting.cancelNextFrame = newValue }
  }

  #endif

  func configureNativeSeekMonitor() {
    nativeSeekMonitor.setHandler { [weak self] landing in
      Task { @MainActor [weak self] in
        self?.nativeSeekDidLand(landing)
      }
    }
    nativeSeekMonitor.setSeekStartedHandler { [weak self] start in
      Task { @MainActor [weak self] in
        self?.nativeSeekDidStart(start)
      }
    }
    nativeSeekMonitor.setExternalSeekLandingHandler { [weak self] landing in
      Task { @MainActor [weak self] in
        self?.nativeExternalSeekDidLand(landing)
      }
    }
    nativeSeekMonitor.setSeekEndedHandler { [weak self] token in
      Task { @MainActor [weak self] in
        self?.nativeSeekDidEnd(token: token)
      }
    }
    nativeSeekMonitor.setSeekDrainAvailabilityHandler { [weak self] in
      Task { @MainActor [weak self] in
        self?.nativeSeekDrainDidClear()
      }
    }
    nativeSeekMonitor.setFrameHandler { [weak self] result in
      Task { @MainActor [weak self] in
        self?.nativeFrameStepDidComplete(result)
      }
    }
    nativeSeekMonitor.setFrameInvalidationHandler { [weak self] frameGeneration in
      Task { @MainActor [weak self] in
        self?.cancelPendingFrameSteps(beforeFrameGeneration: frameGeneration)
      }
    }
    nativeSeekMonitor.setFrameAvailabilityHandler { [weak self] in
      Task { @MainActor [weak self] in
        self?.dispatchNextPendingFrameStepIfNeeded()
      }
    }
  }

  // MARK: - Strict Seeking

  /// Seeks to an absolute time in the current media.
  ///
  /// Throws instead of silently ignoring invalid requests. Check
  /// ``isSeekable`` before exposing scrub controls. The native seek is
  /// asynchronous; after the native call accepts, SwiftVLC publishes the
  /// requested time and derived fractional ``position`` so paused players
  /// update even if libVLC emits no follow-up `timeChanged` event. That value
  /// is optimistic and is reconciled with the authoritative time-watch landing.
  /// libVLC 4 exposes no request ID, so a call made while another seek is
  /// active replaces the one queued intent and returns after local acceptance;
  /// while queued it adopts no timeline revision and publishes no target. A
  /// defensive rejection discovered when it later dispatches cannot be thrown
  /// retroactively.
  ///
  /// - Parameters:
  ///   - time: The absolute target time.
  ///   - fast: Prefer fast (keyframe) seeking over precise seeking.
  ///     Fast seeks land on the nearest keyframe, trading accuracy for
  ///     latency — useful while a scrubber is being dragged.
  /// - Throws: ``VLCError/invalidState(_:)`` if the current media is not
  ///   seekable, or ``VLCError/invalidInput(_:)`` if `time` is negative,
  ///   outside libVLC's millisecond range, or beyond known duration.
  public func seek(to time: Duration, fast: Bool = false) throws(VLCError) {
    _ = try requestSeek(to: time, fast: fast)
  }

  /// Requests an absolute-time seek and exposes its authoritative settlement.
  ///
  /// This completion-reporting counterpart to ``seek(to:fast:)-(Duration,_)``
  /// performs the same strict validation. A pending request may wait behind
  /// one active libVLC 4 seek. Await ``SeekRequest/outcome`` before treating
  /// the requested timeline as landed; synchronous acceptance alone does not
  /// prove that the demuxer honored it.
  ///
  /// - Parameters:
  ///   - time: The absolute target time.
  ///   - fast: Prefer fast (keyframe) seeking over precise seeking.
  /// - Returns: The accepted request and its eventual authoritative outcome.
  /// - Throws: ``VLCError/invalidState(_:)`` if the player is shut down or the
  ///   current media is not seekable; ``VLCError/invalidInput(_:)`` for an
  ///   invalid target; or ``VLCError/operationFailed(_:)`` for an immediate
  ///   native rejection.
  public func requestSeek(
    to time: Duration,
    fast: Bool = false
  )
    throws(VLCError) -> SeekRequest {
    guard !isShutdown else {
      throw .invalidState("requestSeek(to:fast:) called on a player that has been shut down")
    }
    let milliseconds = try checkedSeekMilliseconds(for: time, parameter: "time")
    let evidence = makeSeekSettlementEvidence(requestedTimeMilliseconds: milliseconds)
    guard
      let request = submitNativeSeek(
        operation: .time(milliseconds: milliseconds, fast: fast),
        evidence: evidence,
        publication: .time(milliseconds: milliseconds)
      ) else {
      throw .operationFailed("Seek to \(milliseconds) ms")
    }
    return request
  }

  /// Seeks to a fractional position in the current media.
  ///
  /// `PlaybackPosition` clamps to `0.0 ... 1.0` on construction. This
  /// method still throws if the player does not yet know media duration or
  /// if the current media is not seekable. For live or unknown-duration
  /// media use the non-throwing ``seek(toPosition:fast:)`` instead.
  /// A valid call can be accepted behind one active libVLC 4 seek; in that
  /// case this method returns before the native position call is made and the
  /// observable timeline remains at the active seek until dispatch succeeds.
  ///
  /// - Parameter position: The fractional target in the current media.
  public func seek(to position: PlaybackPosition) throws(VLCError) {
    try seek(to: position, fast: false)
  }

  /// Seeks to a fractional position with explicit keyframe policy.
  ///
  /// - Parameters:
  ///   - position: The fractional target in the current media.
  ///   - fast: Prefer fast (keyframe) seeking over precise seeking. Interactive
  ///     scrubbers should use fast seeks while their value changes, then issue
  ///     one precise seek when editing ends.
  public func seek(
    to position: PlaybackPosition,
    fast: Bool = false
  )
    throws(VLCError) {
    _ = try requestSeek(to: position, fast: fast)
  }

  /// Requests a strict fractional seek and exposes its authoritative
  /// settlement.
  ///
  /// The current duration is required to convert the fraction into one stable
  /// absolute target. For live and unknown-duration media, use
  /// ``requestSeek(toPosition:fast:)`` instead.
  public func requestSeek(
    to position: PlaybackPosition,
    fast: Bool = false
  )
    throws(VLCError) -> SeekRequest {
    guard !isShutdown else {
      throw .invalidState("requestSeek(to:fast:) called on a player that has been shut down")
    }
    guard let duration else {
      throw .invalidState("duration is not known")
    }
    let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
    let target = checkedMilliseconds(for: position, durationMs: durationMs)
    return try requestSeek(to: .milliseconds(target), fast: fast)
  }

  /// Seeks by a relative offset from the current position.
  ///
  /// Negative offsets rewind, positive offsets fast-forward. The target is
  /// clamped to the known playable range after validating the offset.
  /// Because the target is derived from ``currentTime`` and ``duration``,
  /// this only works for media with a known timeline; use ``jump(by:)``
  /// for live or unknown-duration media.
  /// A valid target can be accepted behind one active libVLC 4 seek; in that
  /// case this method returns before the native time call is made and does not
  /// publish the queued target prematurely.
  ///
  /// - Parameters:
  ///   - offset: The relative offset to seek by.
  ///   - fast: Prefer fast (keyframe) seeking over precise seeking.
  ///     Fast seeks land on the nearest keyframe, trading accuracy for
  ///     latency — useful for skip buttons that fire repeatedly.
  /// - Throws: ``VLCError/invalidState(_:)`` if the current media is not
  ///   seekable, or ``VLCError/invalidInput(_:)`` if the offset/current
  ///   time cannot be represented in libVLC's millisecond unit.
  public func seek(by offset: Duration, fast: Bool = false) throws(VLCError) {
    _ = try requestSeek(by: offset, fast: fast)
  }

  /// Requests a strict relative seek and exposes its authoritative settlement.
  ///
  /// Rapid calls accepted while another native seek owns libVLC's watcher are
  /// combined as relative intent and dispatched once. Each public request is
  /// still terminal: an earlier request becomes ``SeekOutcome/superseded``;
  /// the newest request settles normally, or becomes ``SeekOutcome/rejected``
  /// if the aggregate cannot fit VLC's native time domain at dispatch.
  public func requestSeek(
    by offset: Duration,
    fast: Bool = false
  )
    throws(VLCError) -> SeekRequest {
    guard !isShutdown else {
      throw .invalidState("requestSeek(by:fast:) called on a player that has been shut down")
    }
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("current media is awaiting its native playback handle")
    }
    guard isSeekable else {
      throw .invalidState("current media is not seekable")
    }

    let currentMs = try currentTime.checkedMilliseconds(parameter: "currentTime")
    let offsetMs = try offset.checkedLibVLCTimeMilliseconds(parameter: "offset")
    let targetResult = currentMs.addingReportingOverflow(offsetMs)
    guard !targetResult.overflow else {
      throw .invalidInput("offset is outside the supported millisecond range")
    }

    var targetMs = Swift.max(0, targetResult.partialValue)
    if let duration {
      let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
      targetMs = Swift.min(targetMs, durationMs)
    }
    guard LibVLCTimeMilliseconds.contains(targetMs) else {
      throw .invalidInput("offset produces a time outside libVLC's supported range")
    }
    let evidence = makeSeekSettlementEvidence(requestedTimeMilliseconds: targetMs)
    guard
      let request = submitNativeSeek(
        operation: .strictRelative(StrictRelativeSeekIntent(
          baseMilliseconds: currentMs,
          offsetsMilliseconds: [offsetMs],
          fast: fast
        )),
        evidence: evidence,
        publication: .time(milliseconds: targetMs)
      ) else {
      throw .operationFailed("Jump to \(targetMs) ms")
    }
    return request
  }

  /// Publishes a dispatched seek target and marks `revision` as the
  /// authoritative timeline.
  ///
  /// Advancing the revision is what lets the event consumer discard clock
  /// samples libVLC produced before this seek. Without it those queued
  /// samples are applied afterwards and snap the published time back — and
  /// while paused no later native event is guaranteed to repair it.
  ///
  /// `revision` is reserved before native dispatch, then adopted only after
  /// the call reports successful dispatch. A defensive nonzero result leaves
  /// `acceptedTimelineRevision` and any older pending request alone.
  @discardableResult
  func commitSeekTarget(
    milliseconds: Int64,
    revision: UInt64,
    emissionSequence: UInt64 = 0,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    let playbackGeneration = expectedPlaybackGeneration ?? sessionGeneration
    let nativeHandleGeneration = expectedNativeHandleGeneration
      ?? eventBridge.currentNativeHandleGeneration
    let lifecycleControlEpoch = expectedLifecycleControlEpoch
      ?? eventBridge.currentLifecycleControlEpoch
    func stillOwnsTimeline() -> Bool {
      acceptedTimelineRevision == revision
        && lifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch
        && ownsPlaybackMutation(
          playbackGeneration,
          nativeHandleGeneration: nativeHandleGeneration
        )
    }
    guard
      lifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch,
      ownsPlaybackMutation(
        playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration
      )
    else { return false }
    acceptedTimelineRevision = revision
    guard
      performObservableMutation(
        keyPath: \.currentTime,
        ifPlaybackGeneration: playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration,
        timelineRevision: revision,
        lifecycleControlEpoch: lifecycleControlEpoch,
        mutation: {
          storeCurrentTimeWithoutNestedObservation(.milliseconds(milliseconds))
        }
      )
    else { return false }
    let position = publishPosition(
      forTargetMilliseconds: milliseconds,
      ifPlaybackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      timelineRevision: revision,
      lifecycleControlEpoch: lifecycleControlEpoch
    )
    guard
      stillOwnsTimeline(),
      recordAuthoritativeTimeline(
        position: position,
        emissionSequence: emissionSequence,
        ifPlaybackGeneration: playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration,
        timelineRevision: revision,
        lifecycleControlEpoch: lifecycleControlEpoch
      ),
      markPlaybackHealthSeek(
        ifPlaybackGeneration: playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration,
        timelineRevision: revision,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
    else { return false }
    return stillOwnsTimeline()
  }

  // MARK: - Lenient Seeking

  /// Requests a fractional position without validating against media
  /// properties — the API for live, timeshift, and unknown-duration media.
  ///
  /// Unlike the throwing ``seek(to:fast:)-(PlaybackPosition,_)`` (strict, built
  /// for VOD scrubbers), this is a best-effort raw request: it never
  /// throws, does not require a known ``duration``, and simply forwards
  /// the fraction to libVLC. Whether a timeshift input actually accepts
  /// the request is a runtime property of its demuxer, so a `true`
  /// return only means SwiftVLC accepted the seek into its single-flight lane.
  /// It may wait behind one active libVLC 4 seek and does not prove the input
  /// honored it; the observable timeline is reconciled if libVLC later
  /// publishes native landing evidence.
  ///
  /// - Parameters:
  ///   - position: The fractional target, clamped to `0.0 ... 1.0` on
  ///     construction.
  ///   - fast: Prefer fast (keyframe) seeking over precise seeking.
  /// - Returns: `false` when there is no playback session to seek in
  ///   (idle, stopped, or errored player) or an immediate native dispatch
  ///   reports a failure; the call is then a no-op. A queued command can only
  ///   encounter a defensive native rejection later.
  @discardableResult
  public func seek(toPosition position: PlaybackPosition, fast: Bool = false) -> Bool {
    requestSeek(toPosition: position, fast: fast).initialOutcome == .pending
  }

  /// Requests a best-effort fractional seek and exposes its authoritative
  /// settlement.
  ///
  /// Unlike the strict ``requestSeek(to:fast:)-(PlaybackPosition,_)`` overload,
  /// this method works without a known duration and never throws. A pending
  /// result means the request entered SwiftVLC's serialized native seek lane;
  /// await ``SeekRequest/outcome`` to learn whether it landed, timed out, or
  /// was superseded.
  public func requestSeek(
    toPosition position: PlaybackPosition,
    fast: Bool = false
  ) -> SeekRequest {
    guard hasLenientSeekSession else { return SeekRequest(resolved: .rejected) }
    let requestedTimeMilliseconds = duration.flatMap {
      try? $0.checkedNonnegativeMilliseconds(parameter: "duration")
    }.map { checkedMilliseconds(for: position, durationMs: $0) }
    let evidence = makeSeekSettlementEvidence(
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: position.rawValue
    )
    return submitNativeSeek(
      operation: .position(position.rawValue, fast: fast),
      evidence: evidence,
      publication: .position(
        position.rawValue,
        timeMilliseconds: requestedTimeMilliseconds
      )
    ) ?? SeekRequest(resolved: .rejected)
  }

  /// Jumps by a relative offset without validating against media
  /// properties.
  ///
  /// Negative offsets rewind, positive offsets fast-forward. The jump is
  /// performed natively relative to the input's own clock, so it works on
  /// live and unknown-duration media where ``seek(by:fast:)`` cannot
  /// derive a
  /// target from ``currentTime``/``duration``. Best-effort: never throws.
  ///
  /// After a dispatched jump, ``currentTime`` (and ``position``, when
  /// ``duration`` is known) are updated to the best-effort estimate
  /// `currentTime + offset`, clamped to the known playable range, so a
  /// paused player's UI moves immediately. The native jump itself is
  /// asynchronous and the estimate is reconciled from the landed point of the
  /// sole serialized native seek episode (or a newer native time event). Live
  /// streams have no duration, so their ``position`` stays event-driven.
  /// If a relative command replaces a queued absolute or fractional command,
  /// SwiftVLC preserves that base plus the relative offset and resolves the
  /// combined target against the duration current at native dispatch. It then
  /// clamps once to that playable range; metadata growth or shrink while the
  /// command waits therefore cannot freeze an enqueue-time target.
  ///
  /// - Returns: `false` when there is no playback session to seek in
  ///   (idle, stopped, or errored player), the offset does not fit
  ///   libVLC's millisecond unit, or native dispatch reports a failure; the
  ///   call is then a no-op. A `true` result means local acceptance, not
  ///   necessarily immediate native dispatch or eventual landing.
  @discardableResult
  public func jump(by offset: Duration) -> Bool {
    guard let prepared = prepareRelativeSeek(by: offset, publishesEstimate: true) else {
      return false
    }
    return submitNativeSeek(
      operation: .relative(milliseconds: prepared.offsetMilliseconds),
      evidence: prepared.evidence,
      publication: prepared.publication
    ) != nil
  }

  /// Requests a relative jump and exposes when it actually lands.
  ///
  /// This is the completion-reporting counterpart to ``jump(by:)``. The
  /// synchronous ``SeekRequest/initialOutcome`` reports whether SwiftVLC
  /// accepted the command; on libVLC 4 it may still be queued behind one active
  /// seek. Await
  /// ``SeekRequest/outcome`` before telling an asynchronous transport client
  /// (such as AVKit Picture in Picture) that the operation finished.
  ///
  /// Landing evidence from its sole serialized native seek episode settles the
  /// request: normally a watched timer point, or a direct post-end clock read
  /// for paused audio-only playback. A newer seek, media replacement, terminal
  /// playback state, or player teardown supersedes it. If the request waits too
  /// long for native dispatch, or libVLC dispatches it but publishes no
  /// authoritative landing, SwiftVLC returns ``SeekOutcome/timedOut`` after a
  /// bounded interval. Native dispatch restarts that interval so queue time
  /// never consumes the landing budget.
  ///
  /// - Parameter offset: The native relative offset. Negative values rewind;
  ///   positive values fast-forward.
  /// - Returns: A request whose initial result is either pending or rejected.
  public func requestJump(by offset: Duration) -> SeekRequest {
    guard !isShutdown else { return SeekRequest(resolved: .rejected) }
    guard let prepared = prepareRelativeSeek(by: offset, publishesEstimate: false) else {
      return SeekRequest(resolved: .rejected)
    }
    return submitNativeSeek(
      operation: .relative(milliseconds: prepared.offsetMilliseconds),
      evidence: prepared.evidence,
      publication: prepared.publication
    ) ?? SeekRequest(resolved: .rejected)
  }

  func prepareRelativeSeek(
    by offset: Duration,
    publishesEstimate: Bool
  ) -> (
    offsetMilliseconds: Int64,
    evidence: SeekSettlementEvidence,
    publication: SeekOptimisticPublication
  )? {
    guard hasLenientSeekSession else { return nil }
    guard let offsetMs = try? offset.checkedLibVLCTimeMilliseconds(parameter: "offset") else {
      return nil
    }
    let baselineTimeMilliseconds = seekBaselineTimeMilliseconds
    let requestedTimeMilliseconds: Int64?
    if let baselineTimeMilliseconds {
      let result = baselineTimeMilliseconds.addingReportingOverflow(offsetMs)
      if result.overflow {
        requestedTimeMilliseconds = nil
      } else {
        var target = max(0, result.partialValue)
        if
          let duration,
          let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
            parameter: "duration"
          ) {
          target = min(target, durationMilliseconds)
        }
        requestedTimeMilliseconds = target
      }
    } else {
      requestedTimeMilliseconds = nil
    }
    let evidence = makeSeekSettlementEvidence(
      requestedTimeMilliseconds: requestedTimeMilliseconds
    )
    let publication: SeekOptimisticPublication = if
      publishesEstimate,
      let requestedTimeMilliseconds {
      .time(milliseconds: requestedTimeMilliseconds)
    } else {
      .revisionOnly
    }
    return (offsetMs, evidence, publication)
  }

  /// Calls libVLC's absolute-time seek through a deterministic test seam.
  func issueNativeSeek(toMilliseconds milliseconds: Int64, fast: Bool) -> Int32 {
    guard LibVLCTimeMilliseconds.contains(milliseconds) else { return -1 }
    #if DEBUG
    if let _nativeSetTimeOverrideForTesting {
      return _nativeSetTimeOverrideForTesting(milliseconds, fast)
    }
    #endif
    return libvlc_media_player_set_time(pointer, milliseconds, fast)
  }

  /// Calls libVLC through a narrow deterministic test seam.
  func issueNativeSeek(toPosition position: Double, fast: Bool) -> Int32 {
    #if DEBUG
    if let _nativeSetPositionOverrideForTesting {
      return _nativeSetPositionOverrideForTesting(position, fast)
    }
    #endif
    return libvlc_media_player_set_position(pointer, position, fast)
  }

  /// Calls libVLC through a narrow deterministic test seam.
  func issueNativeJump(byMilliseconds offset: Int64) -> Int32 {
    guard LibVLCTimeMilliseconds.contains(offset) else { return -1 }
    #if DEBUG
    if let _nativeJumpTimeOverrideForTesting {
      return _nativeJumpTimeOverrideForTesting(offset)
    }
    #endif
    return libvlc_media_player_jump_time(pointer, offset)
  }

  // Accepts one logical seek into the media-player-local single-flight lane.
  //
  // libVLC 4's watcher has no request ID, so only the active command enters
  // native code. A later command is accepted as the latest queued intent and
  // supersedes the previous public resolver without releasing the active
  // native ownership. A queued command owns only a public reservation: it
  // receives no timeline revision and publishes no target until its native
  // call is actually accepted.
}
