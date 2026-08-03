import CLibVLC

#if DEBUG
struct PlayerSeekTestOverrides {
  var jumpTime: ((Int64) -> Int32)?
  var setPosition: ((Double, Bool) -> Int32)?
  var readLanding: (() -> (timeMilliseconds: Int64, position: Double))?
}
#endif

/// Seeking: strict absolute/relative seeks for VOD scrubbers, lenient
/// best-effort seeks for live and unknown-duration media, and
/// frame-by-frame stepping.
extension Player {
  struct PendingSeekSettlement {
    let playbackGeneration: UInt64
    let timelineRevision: UInt64
    let nativeSeekToken: UInt64
    let resolver: SeekOutcomeResolver
    var timeoutTask: Task<Void, Never>?
  }

  #if DEBUG
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

  #endif

  func configureNativeSeekMonitor() {
    nativeSeekMonitor.setHandler { [weak self] landing in
      Task { @MainActor [weak self] in
        self?.nativeSeekDidLand(landing)
      }
    }
    nativeSeekMonitor.setSeekEndedHandler { [weak self] token in
      Task { @MainActor [weak self] in
        self?.nativeSeekDidEnd(token: token)
      }
    }
  }

  // MARK: - Strict Seeking

  /// Seeks to an absolute time in the current media.
  ///
  /// Throws instead of silently ignoring invalid requests. Check
  /// ``isSeekable`` before exposing scrub controls. The native seek is
  /// asynchronous; SwiftVLC publishes the requested time and the derived
  /// fractional ``position`` immediately after validation so paused
  /// players update their UI even if libVLC does not emit a follow-up
  /// `timeChanged` event.
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
    let milliseconds = try checkedSeekMilliseconds(for: time, parameter: "time")
    // Reserve before native dispatch so synchronous seek callbacks carry the
    // revision this accepted command can adopt. Rejection leaves the existing
    // accepted revision and pending request untouched.
    let revision = eventBridge.advanceTimelineRevision()
    let nativeSeekToken = nativeSeekMonitor.stageCommand()
    // Publishing before checking the result reported a target libVLC had
    // refused, leaving the observable timeline describing a position playback
    // never reached.
    guard libvlc_media_player_set_time(pointer, milliseconds, fast) == 0 else {
      nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
      throw .operationFailed("Seek to \(milliseconds) ms")
    }
    supersedePendingSeekSettlement()
    commitSeekTarget(milliseconds: milliseconds, revision: revision)
  }

  /// Seeks to a fractional position in the current media.
  ///
  /// `PlaybackPosition` clamps to `0.0 ... 1.0` on construction. This
  /// method still throws if the player does not yet know media duration or
  /// if the current media is not seekable. For live or unknown-duration
  /// media use the non-throwing ``seek(toPosition:fast:)`` instead.
  public func seek(to position: PlaybackPosition) throws(VLCError) {
    guard let duration else {
      throw .invalidState("duration is not known")
    }
    let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
    let target = checkedMilliseconds(for: position, durationMs: durationMs)
    try seek(to: .milliseconds(target))
  }

  /// Seeks by a relative offset from the current position.
  ///
  /// Negative offsets rewind, positive offsets fast-forward. The target is
  /// clamped to the known playable range after validating the offset.
  /// Because the target is derived from ``currentTime`` and ``duration``,
  /// this only works for media with a known timeline; use ``jump(by:)``
  /// for live or unknown-duration media.
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
    guard isSeekable else {
      throw .invalidState("current media is not seekable")
    }

    let currentMs = try currentTime.checkedMilliseconds(parameter: "currentTime")
    let offsetMs = try offset.checkedMilliseconds(parameter: "offset")
    let targetResult = currentMs.addingReportingOverflow(offsetMs)
    guard !targetResult.overflow else {
      throw .invalidInput("offset is outside the supported millisecond range")
    }

    var targetMs = Swift.max(0, targetResult.partialValue)
    if let duration {
      let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
      targetMs = Swift.min(targetMs, durationMs)
    }

    let revision = eventBridge.advanceTimelineRevision()
    let nativeSeekToken = nativeSeekMonitor.stageCommand()
    guard libvlc_media_player_set_time(pointer, targetMs, fast) == 0 else {
      nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
      throw .operationFailed("Jump to \(targetMs) ms")
    }
    supersedePendingSeekSettlement()
    commitSeekTarget(milliseconds: targetMs, revision: revision)
  }

  /// Publishes an accepted seek target and marks `revision` as the
  /// authoritative timeline.
  ///
  /// Advancing the revision is what lets the event consumer discard clock
  /// samples libVLC produced before this seek. Without it those queued
  /// samples are applied afterwards and snap the published time back — and
  /// while paused no later native event is guaranteed to repair it.
  ///
  /// `revision` is reserved before native dispatch, then adopted only after
  /// libVLC accepts. A rejected seek therefore leaves
  /// `acceptedTimelineRevision` and any older pending request alone.
  func commitSeekTarget(milliseconds: Int64, revision: UInt64) {
    acceptedTimelineRevision = revision
    currentTime = .milliseconds(milliseconds)
    let position = publishPosition(forTargetMilliseconds: milliseconds)
    recordAuthoritativeTimeline(position: position)
    markPlaybackHealthSeek()
  }

  // MARK: - Lenient Seeking

  /// Requests a fractional position without validating against media
  /// properties — the API for live, timeshift, and unknown-duration media.
  ///
  /// Unlike the throwing ``seek(to:)-(PlaybackPosition)`` (strict, built
  /// for VOD scrubbers), this is a best-effort raw request: it never
  /// throws, does not require a known ``duration``, and simply forwards
  /// the fraction to libVLC. Whether a timeshift input actually accepts
  /// the request is a runtime property of its demuxer, so a `true`
  /// return only means libVLC queued the seek.
  ///
  /// - Parameters:
  ///   - position: The fractional target, clamped to `0.0 ... 1.0` on
  ///     construction.
  ///   - fast: Prefer fast (keyframe) seeking over precise seeking.
  /// - Returns: `false` when there is no playback session to seek in
  ///   (idle, stopped, or errored player) or libVLC rejects the request;
  ///   the call is then a no-op.
  @discardableResult
  public func seek(toPosition position: PlaybackPosition, fast: Bool = false) -> Bool {
    guard hasLenientSeekSession else { return false }
    let revision = eventBridge.advanceTimelineRevision()
    let nativeSeekToken = nativeSeekMonitor.stageCommand()
    guard issueNativeSeek(toPosition: position.rawValue, fast: fast) == 0 else {
      nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
      return false
    }
    supersedePendingSeekSettlement()
    acceptedTimelineRevision = revision
    withMutation(keyPath: \.position) {
      _position = position.rawValue
    }
    if
      let duration,
      let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration") {
      currentTime = .milliseconds(checkedMilliseconds(for: position, durationMs: durationMs))
    }
    recordAuthoritativeTimeline(position: position.rawValue)
    markPlaybackHealthSeek()
    return true
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
  /// After an accepted jump, ``currentTime`` (and ``position``, when
  /// ``duration`` is known) are updated to the best-effort estimate
  /// `currentTime + offset`, clamped to the known playable range, so a
  /// paused player's UI moves immediately. The native jump itself is
  /// asynchronous and the estimate is corrected by the next native time
  /// event; live streams have no duration, so their ``position`` stays
  /// purely event-driven.
  ///
  /// - Returns: `false` when there is no playback session to seek in
  ///   (idle, stopped, or errored player), the offset does not fit
  ///   libVLC's millisecond unit, or libVLC rejects the request; the
  ///   call is then a no-op.
  @discardableResult
  public func jump(by offset: Duration) -> Bool {
    issueRelativeJump(by: offset, publishesEstimate: true, nativeSeekToken: nil) != nil
  }

  /// Requests a relative jump and exposes when it actually lands.
  ///
  /// This is the authoritative counterpart to ``jump(by:)``. The synchronous
  /// ``SeekRequest/initialOutcome`` reports native acceptance. Await
  /// ``SeekRequest/outcome`` before telling an asynchronous transport client
  /// (such as AVKit Picture in Picture) that the operation finished.
  ///
  /// Native landing evidence after libVLC's matching seek-end callback settles
  /// the request: normally a watched timer point, or a direct post-end clock
  /// read for paused audio-only playback. A newer seek, media replacement,
  /// terminal playback state, or player teardown supersedes it. If libVLC
  /// accepts the command but publishes no authoritative landing, SwiftVLC
  /// returns ``SeekOutcome/timedOut`` after a bounded interval.
  ///
  /// - Parameter offset: The native relative offset. Negative values rewind;
  ///   positive values fast-forward.
  /// - Returns: A request whose initial result is either pending or rejected.
  public func requestJump(by offset: Duration) -> SeekRequest {
    let nativeSeekToken = nativeSeekMonitor.stageCommand()
    guard
      let revision = issueRelativeJump(
        by: offset,
        publishesEstimate: false,
        nativeSeekToken: nativeSeekToken
      ) else {
      nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
      return SeekRequest(resolved: .rejected)
    }
    return registerPendingSeekSettlement(
      playbackGeneration: sessionGeneration,
      timelineRevision: revision,
      nativeSeekToken: nativeSeekToken
    )
  }

  /// One native relative-jump path shared by the legacy acceptance-only API
  /// and the authoritative request API. Keeping settlement allocation out of
  /// ``jump(by:)`` preserves its lightweight behavior for callers that only
  /// need dispatch acceptance.
  private func issueRelativeJump(
    by offset: Duration,
    publishesEstimate: Bool,
    nativeSeekToken: UInt64?
  ) -> UInt64? {
    guard hasLenientSeekSession else { return nil }
    guard let offsetMs = try? offset.checkedMilliseconds(parameter: "offset") else {
      return nil
    }
    let revision = eventBridge.advanceTimelineRevision()
    let commandToken = nativeSeekToken ?? nativeSeekMonitor.stageCommand()
    guard issueNativeJump(byMilliseconds: offsetMs) == 0 else {
      nativeSeekMonitor.cancelStagedCommand(commandToken)
      return nil
    }
    #if DEBUG
    if nativeSeekToken != nil, _nativeJumpTimeOverrideForTesting != nil {
      nativeSeekMonitor._noteSeekStartedForTesting()
    }
    #endif
    // Only an accepted replacement supersedes the prior request. If libVLC
    // rejects this jump, the earlier accepted command can still land and must
    // retain both its timeline authority and its terminal result.
    supersedePendingSeekSettlement()
    acceptedTimelineRevision = revision
    if
      publishesEstimate,
      let currentMs = try? currentTime.checkedMilliseconds(parameter: "currentTime") {
      let targetResult = currentMs.addingReportingOverflow(offsetMs)
      if !targetResult.overflow {
        var targetMs = Swift.max(0, targetResult.partialValue)
        if
          let duration,
          let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration") {
          targetMs = Swift.min(targetMs, durationMs)
        }
        currentTime = .milliseconds(targetMs)
        let position = publishPosition(forTargetMilliseconds: targetMs)
        recordAuthoritativeTimeline(position: position)
      }
    }
    markPlaybackHealthSeek()
    return revision
  }

  /// Calls libVLC through a narrow deterministic test seam.
  private func issueNativeSeek(toPosition position: Double, fast: Bool) -> Int32 {
    #if DEBUG
    if let _nativeSetPositionOverrideForTesting {
      return _nativeSetPositionOverrideForTesting(position, fast)
    }
    #endif
    return libvlc_media_player_set_position(pointer, position, fast)
  }

  /// Calls libVLC through a narrow deterministic test seam.
  private func issueNativeJump(byMilliseconds offset: Int64) -> Int32 {
    #if DEBUG
    if let _nativeJumpTimeOverrideForTesting {
      return _nativeJumpTimeOverrideForTesting(offset)
    }
    #endif
    return libvlc_media_player_jump_time(pointer, offset)
  }

  /// Creates the single pending request and starts its bounded timeout.
  private func registerPendingSeekSettlement(
    playbackGeneration: UInt64,
    timelineRevision: UInt64,
    nativeSeekToken: UInt64
  ) -> SeekRequest {
    let resolver = SeekOutcomeResolver()
    pendingSeekSettlement = PendingSeekSettlement(
      playbackGeneration: playbackGeneration,
      timelineRevision: timelineRevision,
      nativeSeekToken: nativeSeekToken,
      resolver: resolver,
      timeoutTask: nil
    )
    let timeoutTask = Task { @MainActor [weak self, weak resolver] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard let resolver else { return }
      self?.resolvePendingSeekSettlement(resolver: resolver, as: .timedOut)
    }
    pendingSeekSettlement?.timeoutTask = timeoutTask
    return SeekRequest(resolver: resolver)
  }

  /// Applies libVLC's authoritative landed point after the matching seek ends.
  /// Ordinary pre-seek and in-flight time callbacks cannot produce this token.
  func nativeSeekDidLand(_ landing: NativeSeekLanding) {
    guard
      let pendingSeekSettlement,
      pendingSeekSettlement.nativeSeekToken == landing.token,
      pendingSeekSettlement.playbackGeneration == sessionGeneration
    else { return }

    let nativeTime = landing.timeMilliseconds
    guard nativeTime >= 0 else { return }
    // The landing itself is a new authority boundary. Native event callbacks
    // that entered after dispatch but before seek-start still carry the
    // accepted request revision; advancing here prevents those queued old
    // clock samples from overwriting the landed point after settlement.
    acceptedTimelineRevision = eventBridge.advanceTimelineRevision()
    currentTime = .milliseconds(nativeTime)
    let nativePosition = landing.position
    let authoritativePosition: Double?
    if nativePosition.isFinite, (0.0...1.0).contains(nativePosition) {
      withMutation(keyPath: \.position) {
        _position = nativePosition
      }
      authoritativePosition = nativePosition
    } else {
      authoritativePosition = publishPosition(forTargetMilliseconds: nativeTime)
    }
    eventBridge.updateAuthoritativeTimeline(
      time: currentTime,
      position: authoritativePosition,
      playbackGeneration: sessionGeneration,
      timelineRevision: acceptedTimelineRevision
    )
    resolvePendingSeekSettlement(
      resolver: pendingSeekSettlement.resolver,
      as: .settled
    )
  }

  /// A paused audio-only input may emit seek-end without another watched time
  /// point. Read the authoritative native clock after leaving the C callback,
  /// on the main actor, so those requests can settle without waiting for
  /// playback to resume. Video and actively playing sessions may still settle
  /// through the watched point first; token matching makes the paths idempotent.
  func nativeSeekDidEnd(token: UInt64) {
    guard
      let pendingSeekSettlement,
      pendingSeekSettlement.nativeSeekToken == token,
      pendingSeekSettlement.playbackGeneration == sessionGeneration,
      nativePlaybackState == .paused
    else { return }

    let landing: NativeSeekLanding
    #if DEBUG
    if let override = _nativeSeekLandingOverrideForTesting {
      let point = override()
      landing = NativeSeekLanding(
        token: token,
        timeMilliseconds: point.timeMilliseconds,
        position: point.position
      )
    } else {
      landing = NativeSeekLanding(
        token: token,
        timeMilliseconds: libvlc_media_player_get_time(pointer),
        position: libvlc_media_player_get_position(pointer)
      )
    }
    #else
    landing = NativeSeekLanding(
      token: token,
      timeMilliseconds: libvlc_media_player_get_time(pointer),
      position: libvlc_media_player_get_position(pointer)
    )
    #endif
    nativeSeekDidLand(landing)
  }

  /// Invalidates the current request before another timeline owner is
  /// established.
  func supersedePendingSeekSettlement(ifNotPredating timelineRevision: UInt64? = nil) {
    guard let pendingSeekSettlement else { return }
    if let timelineRevision, timelineRevision < pendingSeekSettlement.timelineRevision {
      return
    }
    resolvePendingSeekSettlement(resolver: pendingSeekSettlement.resolver, as: .superseded)
  }

  private func resolvePendingSeekSettlement(
    resolver: SeekOutcomeResolver,
    as outcome: SeekOutcome
  ) {
    guard
      let pendingSeekSettlement,
      pendingSeekSettlement.resolver === resolver
    else { return }
    self.pendingSeekSettlement = nil
    pendingSeekSettlement.timeoutTask?.cancel()
    resolver.resolve(outcome)
  }

  #if DEBUG
  /// Deterministic timeout seam; production uses the bounded task above.
  func _expirePendingSeekForTesting() {
    guard let resolver = pendingSeekSettlement?.resolver else { return }
    resolvePendingSeekSettlement(resolver: resolver, as: .timedOut)
  }

  func _completePendingSeekForTesting(
    time: Duration,
    position: Double? = nil,
    token: UInt64? = nil
  ) {
    guard let pendingSeekSettlement else { return }
    let milliseconds = try? time.checkedMilliseconds(parameter: "time")
    nativeSeekDidLand(NativeSeekLanding(
      token: token ?? pendingSeekSettlement.nativeSeekToken,
      timeMilliseconds: milliseconds ?? -1,
      position: position ?? -.infinity
    ))
  }
  #endif

  /// Whether the player is in a lifecycle state where a lenient seek can
  /// take effect. libVLC 4's seek entry points queue the request under
  /// the player lock and report success even when no media is loaded, so
  /// the no-op `false` contract needs this state gate in front of the
  /// native call. The event-fed ``state`` mirror lags one main-actor
  /// turn, so the gate reads the synchronous signals instead: the
  /// playback-intent flag (set by `play()`/`resume()` before this can
  /// run) covers a seek issued in the same turn as the play call, and
  /// the native state read covers paused sessions — a paused session
  /// still has an input to seek in — while rejecting terminal native
  /// states the mirror has not caught up with yet.
  private var hasLenientSeekSession: Bool {
    if isPlaybackRequestedActive {
      return true
    }
    switch nativePlaybackState {
    case .opening, .buffering, .playing, .paused:
      return true
    case .idle, .stopped, .stopping, .error:
      return false
    }
  }

  // MARK: - Frame Stepping

  /// Pauses playback and advances one video frame.
  ///
  /// Requires the current media to be pausable (see ``isPausable``).
  /// Calling repeatedly yields frame-by-frame stepping.
  public func nextFrame() {
    supersedePendingSeekSettlement()
    libvlc_media_player_next_frame(pointer)
    // libVLC doesn't emit `MediaPlayerTimeChanged` after a next-frame
    // step while paused: the decoder advances one frame but the event
    // thread stays quiescent. Read the authoritative time directly so
    // `currentTime` reflects the step.
    let ms = libvlc_media_player_get_time(pointer)
    if ms >= 0 {
      // The direct read is the frame step's authority boundary. Reject clock
      // callbacks that entered before it and could otherwise overwrite the
      // stepped point after this main-actor turn.
      acceptedTimelineRevision = eventBridge.advanceTimelineRevision()
      currentTime = .milliseconds(ms)
      recordAuthoritativeTimeline(position: nil)
    }
  }

  // MARK: - Validation

  private func checkedSeekMilliseconds(for time: Duration, parameter: String) throws(VLCError) -> Int64 {
    guard isSeekable else {
      throw .invalidState("current media is not seekable")
    }

    let milliseconds = try time.checkedNonnegativeMilliseconds(parameter: parameter)
    if let duration {
      let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
      guard milliseconds <= durationMs else {
        throw .invalidInput("\(parameter) must not exceed current media duration")
      }
    }
    return milliseconds
  }

  private func checkedMilliseconds(for position: PlaybackPosition, durationMs: Int64) -> Int64 {
    guard position.rawValue > 0 else { return 0 }
    guard position.rawValue < 1 else { return durationMs }

    let scaled = (Double(durationMs) * position.rawValue).rounded()
    guard scaled.isFinite, scaled > 0 else { return 0 }
    guard scaled < Double(Int64.max) else { return durationMs }
    return Swift.min(Int64(scaled), durationMs)
  }

  /// Publishes the fractional position derived from a just-issued seek
  /// target. libVLC emits no `positionChanged` while paused, so without
  /// this the ``position`` shadow would stay stale until playback resumes.
  @discardableResult
  func publishPosition(forTargetMilliseconds targetMs: Int64) -> Double? {
    guard
      let duration,
      let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration"),
      durationMs > 0
    else { return nil }
    let fraction = Swift.min(1.0, Swift.max(0.0, Double(targetMs) / Double(durationMs)))
    withMutation(keyPath: \.position) {
      _position = fraction
    }
    return fraction
  }

  /// Keeps terminal outcomes aligned with synchronous timeline mutations for
  /// which libVLC does not guarantee a corresponding event.
  private func recordAuthoritativeTimeline(position: Double?) {
    eventBridge.updateAuthoritativeTimeline(
      time: currentTime,
      position: position,
      playbackGeneration: sessionGeneration,
      timelineRevision: acceptedTimelineRevision
    )
  }
}
