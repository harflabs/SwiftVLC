import CLibVLC

/// Seeking: strict absolute/relative seeks for VOD scrubbers, lenient
/// best-effort seeks for live and unknown-duration media, and
/// frame-by-frame stepping.
extension Player {
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
    // Reserved *before* the native call: libVLC delivers events on its own
    // thread, so a post-seek clock sample emitted while `set_time` is still
    // returning would otherwise be stamped with the previous revision and
    // then discarded as stale — losing the position the seek actually landed
    // on, which after a fast (keyframe) seek is not the requested one.
    let revision = eventBridge.advanceTimelineRevision()
    // Publishing before checking the result reported a target libVLC had
    // refused, leaving the observable timeline describing a position playback
    // never reached.
    guard libvlc_media_player_set_time(pointer, milliseconds, fast) == 0 else {
      throw .operationFailed("Seek to \(milliseconds) ms")
    }
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

    // See `seek(to:fast:)`: reserved before the native call so a post-seek
    // sample cannot be stamped with the outgoing revision.
    let revision = eventBridge.advanceTimelineRevision()
    guard libvlc_media_player_set_time(pointer, targetMs, fast) == 0 else {
      throw .operationFailed("Jump to \(targetMs) ms")
    }
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
  /// `revision` is reserved by the caller *before* it issues the native seek,
  /// so it is only adopted here once libVLC has accepted the request. A
  /// rejected seek leaves `acceptedTimelineRevision` alone; the reserved
  /// value is simply never adopted, which keeps clock samples flowing exactly
  /// as they did before the refused request.
  func commitSeekTarget(milliseconds: Int64, revision: UInt64) {
    acceptedTimelineRevision = revision
    currentTime = .milliseconds(milliseconds)
    publishPosition(forTargetMilliseconds: milliseconds)
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
    // Reserved before the native call for the same reason as the strict
    // paths, and adopted only once libVLC accepts: a lenient seek publishes a
    // position the same way a strict one does, so pre-seek samples must not
    // overwrite it either.
    let revision = eventBridge.advanceTimelineRevision()
    guard libvlc_media_player_set_position(pointer, position.rawValue, fast) == 0 else {
      return false
    }
    acceptedTimelineRevision = revision
    withMutation(keyPath: \.position) {
      _position = position.rawValue
    }
    if
      let duration,
      let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration") {
      currentTime = .milliseconds(checkedMilliseconds(for: position, durationMs: durationMs))
    }
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
    guard hasLenientSeekSession else { return false }
    guard let offsetMs = try? offset.checkedMilliseconds(parameter: "offset") else {
      return false
    }
    // Reserved before the native call and adopted only once libVLC accepts,
    // exactly as the absolute paths do. A relative jump needs this more than
    // they do, not less: it is issued while playback is running and clock
    // samples are in flight, so without it a sample produced just before the
    // jump lands afterwards and snaps the published time back to where
    // playback used to be. A refused jump must not consume the reservation,
    // or every later sample would be judged stale against a revision nothing
    // adopted.
    let revision = eventBridge.advanceTimelineRevision()
    guard libvlc_media_player_jump_time(pointer, offsetMs) == 0 else {
      return false
    }
    acceptedTimelineRevision = revision
    if let currentMs = try? currentTime.checkedMilliseconds(parameter: "currentTime") {
      let targetResult = currentMs.addingReportingOverflow(offsetMs)
      if !targetResult.overflow {
        var targetMs = Swift.max(0, targetResult.partialValue)
        if
          let duration,
          let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration") {
          targetMs = Swift.min(targetMs, durationMs)
        }
        currentTime = .milliseconds(targetMs)
        publishPosition(forTargetMilliseconds: targetMs)
      }
    }
    return true
  }

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
    libvlc_media_player_next_frame(pointer)
    // libVLC doesn't emit `MediaPlayerTimeChanged` after a next-frame
    // step while paused: the decoder advances one frame but the event
    // thread stays quiescent. Read the authoritative time directly so
    // `currentTime` reflects the step.
    let ms = libvlc_media_player_get_time(pointer)
    if ms >= 0 {
      currentTime = .milliseconds(ms)
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
  private func publishPosition(forTargetMilliseconds targetMs: Int64) {
    guard
      let duration,
      let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration"),
      durationMs > 0
    else { return }
    let fraction = Swift.min(1.0, Swift.max(0.0, Double(targetMs) / Double(durationMs)))
    withMutation(keyPath: \.position) {
      _position = fraction
    }
  }
}
