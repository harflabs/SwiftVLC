import CLibVLC
import Synchronization

struct NativeSeekLanding: Sendable {
  let token: UInt64
  let timeMilliseconds: Int64
  let position: Double
  /// Total order assigned by the callback authority before this landing is
  /// handed to another executor. Zero is reserved for direct DEBUG seams.
  let emissionSequence: UInt64
  let isVideoOutput: Bool
  let frameDurationMicroseconds: Int64

  init(
    token: UInt64,
    timeMilliseconds: Int64,
    position: Double,
    emissionSequence: UInt64 = 0,
    isVideoOutput: Bool = false,
    frameDurationMicroseconds: Int64 = 0
  ) {
    self.token = token
    self.timeMilliseconds = timeMilliseconds
    self.position = position
    self.emissionSequence = emissionSequence
    self.isVideoOutput = isVideoOutput
    self.frameDurationMicroseconds = frameDurationMicroseconds
  }
}

struct NativeSeekStart: Sendable {
  /// The wrapper token consumed by this start, or `nil` for a seek issued
  /// directly against the native player outside SwiftVLC.
  let token: UInt64?
  /// Monotonic identity of externally-issued native seek episodes. Commands
  /// accepted after an external start capture the new epoch even if delivery
  /// to the main actor is still queued.
  let externalEpoch: UInt64
}

struct NativeExternalSeekLanding: Sendable {
  /// Watch attachment which observed this episode. A landing can already be
  /// queued for MainActor delivery when media, playback, or the native handle
  /// is replaced, so the external epoch alone is not a sufficient identity.
  let timelineGeneration: UInt64
  let nativeHandleGeneration: UInt64
  let playbackGeneration: UInt64
  /// External epoch captured synchronously by the watcher start callback.
  let externalEpoch: UInt64
  let timeMilliseconds: Int64
  let position: Double
  /// Total callback-emission order shared with raw clock and frame events.
  let emissionSequence: UInt64

  init(
    timelineGeneration: UInt64,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64,
    externalEpoch: UInt64,
    timeMilliseconds: Int64,
    position: Double,
    emissionSequence: UInt64 = 0
  ) {
    self.timelineGeneration = timelineGeneration
    self.nativeHandleGeneration = nativeHandleGeneration
    self.playbackGeneration = playbackGeneration
    self.externalEpoch = externalEpoch
    self.timeMilliseconds = timeMilliseconds
    self.position = position
    self.emissionSequence = emissionSequence
  }
}

/// Seek ownership captured on the native callback thread at emission time.
///
/// libVLC 4 does not tag ordinary time/position events with the seek episode
/// which produced them. The time watcher and EventBridge therefore share this
/// tiny authority cell: an EventBridge callback which enters while an
/// externally-issued episode is unresolved keeps that quarantine stamp even
/// if MainActor delivery happens after the episode advances or drains.
struct NativeSeekEmissionStamp: Equatable, Sendable {
  let timelineGeneration: UInt64
  let externalEpoch: UInt64
  let externalDrainPending: Bool
  let externalOverlapAmbiguous: Bool
  /// Monotonic order shared by EventBridge, watched seek landings, wrapper
  /// dispatch barriers, and exact frame completion.
  let timelineEmissionSequence: UInt64
}

/// Timeline evidence committed on a native callback lane before any hop to
/// MainActor. Terminal callbacks use the same emission authority to capture
/// the newest earlier value, so an already-emitted seek landing or exact frame
/// cannot disappear merely because its UI delivery is still queued.
struct NativeTimelineCallbackEmission: Equatable, Sendable {
  let timelineGeneration: UInt64
  let playbackGeneration: UInt64
  let timeMilliseconds: Int64?
  let position: Double?
  let timelineEmissionSequence: UInt64
}

struct NativeTimelineCallbackEntry: Sendable {
  let seekStamp: NativeSeekEmissionStamp
  let latestTimelineEmission: NativeTimelineCallbackEmission?
}

final class NativeSeekEmissionAuthority: Sendable {
  private struct State: Sendable {
    var timelineGeneration: UInt64 = 1
    var externalEpoch: UInt64 = 0
    var externalDrainPending = false
    var externalOverlapAmbiguous = false
    var timelineEmissionSequence: UInt64 = 0
    var latestTimelineEmission: NativeTimelineCallbackEmission?

    var stamp: NativeSeekEmissionStamp {
      NativeSeekEmissionStamp(
        timelineGeneration: timelineGeneration,
        externalEpoch: externalEpoch,
        externalDrainPending: externalDrainPending,
        externalOverlapAmbiguous: externalOverlapAmbiguous,
        timelineEmissionSequence: timelineEmissionSequence
      )
    }
  }

  private let state = Mutex(State())

  func capture() -> NativeSeekEmissionStamp {
    state.withLock { state in
      precondition(
        state.timelineEmissionSequence < UInt64.max,
        "Native timeline emission sequence exhausted"
      )
      state.timelineEmissionSequence += 1
      return state.stamp
    }
  }

  /// Captures terminal ordering and the newest earlier watcher/frame emission
  /// under one lock. A later callback can obtain a larger sequence, but can
  /// never be retroactively folded into this terminal entry.
  func captureCallbackEntry() -> NativeTimelineCallbackEntry {
    state.withLock { state in
      Self.makeCallbackEntry(in: &state)
    }
  }

  /// Reserves native callback order and captures a second authority while the
  /// native-emission lock is still held. This gives terminal callbacks one
  /// indivisible boundary: a watcher/frame emission and a committed timeline
  /// snapshot are either both earlier than the callback or both later.
  ///
  /// Callers must never acquire this authority while already holding the
  /// authority captured by `captureCheckpoint`.
  func captureCallbackEntry<Checkpoint: Sendable>(
    capturing captureCheckpoint: @Sendable (NativeTimelineCallbackEntry) -> Checkpoint
  ) -> (entry: NativeTimelineCallbackEntry, checkpoint: Checkpoint) {
    state.withLock { state in
      let entry = Self.makeCallbackEntry(in: &state)
      return (entry, captureCheckpoint(entry))
    }
  }

  /// Serializes a wrapper-originated lifecycle mutation with native callback
  /// entry. The closure may acquire `playbackLifecycle` and then the terminal
  /// timeline authority; callers must never enter this method while holding
  /// either of those locks. This is the single production lock order:
  /// native emission -> playback lifecycle -> terminal timeline.
  func withCallbackOrdering<Result: Sendable>(
    _ operation: @Sendable () -> Result
  ) -> Result {
    state.withLock { _ in operation() }
  }

  /// Serializes a wrapper lifecycle transaction with callback entry and gives
  /// it the newest watcher/frame timeline fact already committed on this lane.
  /// The value is immutable for the duration of `operation`; a later native
  /// callback receives a strictly later ordering point.
  func withCallbackOrderingSnapshot<Result: Sendable>(
    _ operation: @Sendable (NativeTimelineCallbackEmission?) -> Result
  ) -> Result {
    state.withLock { state in
      operation(state.latestTimelineEmission)
    }
  }

  private static func makeCallbackEntry(
    in state: inout State
  ) -> NativeTimelineCallbackEntry {
    precondition(
      state.timelineEmissionSequence < UInt64.max,
      "Native timeline emission sequence exhausted"
    )
    state.timelineEmissionSequence += 1
    let stamp = state.stamp
    let latest: NativeTimelineCallbackEmission? = state.latestTimelineEmission.flatMap { emission in
      guard
        emission.timelineGeneration == stamp.timelineGeneration,
        emission.timelineEmissionSequence < stamp.timelineEmissionSequence
      else { return nil }
      return emission
    }
    return NativeTimelineCallbackEntry(
      seekStamp: stamp,
      latestTimelineEmission: latest
    )
  }

  /// Establishes an ordering barrier even when there is no raw libVLC event.
  /// A wrapper seek adopts this value only after native dispatch succeeds.
  func advanceTimelineEmissionSequence() -> UInt64 {
    state.withLock { state in
      precondition(
        state.timelineEmissionSequence < UInt64.max,
        "Native timeline emission sequence exhausted"
      )
      state.timelineEmissionSequence += 1
      return state.timelineEmissionSequence
    }
  }

  /// Assigns an emission order and stores its authoritative clock point in one
  /// critical section. Both values therefore become visible to a following
  /// terminal callback together or not at all.
  func recordTimelineAndAdvance(
    timelineGeneration: UInt64,
    playbackGeneration: UInt64,
    timeMilliseconds: Int64?,
    position: Double?
  ) -> UInt64 {
    state.withLock { state in
      precondition(
        state.timelineEmissionSequence < UInt64.max,
        "Native timeline emission sequence exhausted"
      )
      state.timelineEmissionSequence += 1
      let sequence = state.timelineEmissionSequence
      guard
        timelineGeneration == state.timelineGeneration,
        timeMilliseconds != nil || position != nil
      else { return sequence }
      state.latestTimelineEmission = NativeTimelineCallbackEmission(
        timelineGeneration: timelineGeneration,
        playbackGeneration: playbackGeneration,
        timeMilliseconds: timeMilliseconds,
        position: position,
        timelineEmissionSequence: sequence
      )
      return sequence
    }
  }

  /// Atomically stores an external watched landing and exposes the drained
  /// stamp to later callbacks. A terminal callback therefore observes either
  /// both the authoritative point and cleared quarantine, or neither.
  func finishExternalDrainAndAdvance(
    timelineGeneration: UInt64,
    playbackGeneration: UInt64,
    externalEpoch: UInt64,
    timeMilliseconds: Int64?,
    position: Double?
  ) -> UInt64 {
    state.withLock { state in
      precondition(
        state.timelineEmissionSequence < UInt64.max,
        "Native timeline emission sequence exhausted"
      )
      precondition(
        state.timelineGeneration == timelineGeneration,
        "External seek landing crossed a timeline replacement"
      )
      state.externalEpoch = externalEpoch
      state.externalDrainPending = false
      state.externalOverlapAmbiguous = false
      state.timelineEmissionSequence += 1
      let sequence = state.timelineEmissionSequence
      if timeMilliseconds != nil || position != nil {
        state.latestTimelineEmission = NativeTimelineCallbackEmission(
          timelineGeneration: timelineGeneration,
          playbackGeneration: playbackGeneration,
          timeMilliseconds: timeMilliseconds,
          position: position,
          timelineEmissionSequence: sequence
        )
      }
      return sequence
    }
  }

  func update(
    timelineGeneration: UInt64,
    externalEpoch: UInt64,
    externalDrainPending: Bool,
    externalOverlapAmbiguous: Bool
  ) {
    state.withLock { state in
      if state.timelineGeneration != timelineGeneration {
        state.latestTimelineEmission = nil
      }
      state.timelineGeneration = timelineGeneration
      state.externalEpoch = externalEpoch
      state.externalDrainPending = externalDrainPending
      state.externalOverlapAmbiguous = externalOverlapAmbiguous
    }
  }
}

private struct NativeSeekInvocationClaim: Sendable {
  let context: ObjectIdentifier
  let token: UInt64
}

/// libVLC 4 has no seek request identifier, but its v4 setter path emits the
/// watcher start synchronously. A task-local claim proves that a callback is
/// re-entering Swift from this exact setter invocation. An asynchronous or
/// independently-issued start has no claim and is deliberately external.
private enum NativeSeekInvocationAuthority {
  @TaskLocal static var current: NativeSeekInvocationClaim?

  static func token(for context: NativeSeekContext) -> UInt64? {
    guard current?.context == ObjectIdentifier(context) else { return nil }
    return current?.token
  }
}

enum NativeFrameRequestDispatch: Equatable, Sendable {
  case accepted
  case busy
  case unavailable
}

struct NativeFrameStepResult: Sendable {
  let token: UInt64
  let status: Int32
  let timeMicroseconds: Int64
  let position: Double
  /// Total callback-emission order shared with seek and raw clock events.
  let emissionSequence: UInt64

  init(
    token: UInt64,
    status: Int32,
    timeMicroseconds: Int64,
    position: Double,
    emissionSequence: UInt64 = 0
  ) {
    self.token = token
    self.status = status
    self.timeMicroseconds = timeMicroseconds
    self.position = position
    self.emissionSequence = emissionSequence
  }
}

enum NativeFrameStepTerminalStatus: Equatable, Sendable {
  case success
  case pausedForRetry
  case noFrame
  case failed(Int32)

  init(rawValue: Int32) {
    switch rawValue {
    case Int32(swiftvlc_frame_step_status_success.rawValue):
      self = .success
    case Int32(swiftvlc_frame_step_status_paused_for_retry.rawValue):
      self = .pausedForRetry
    case Int32(swiftvlc_frame_step_status_no_frame.rawValue):
      self = .noFrame
    default:
      self = .failed(rawValue)
    }
  }

  var rawValue: Int32 {
    switch self {
    case .success:
      Int32(swiftvlc_frame_step_status_success.rawValue)
    case .pausedForRetry:
      Int32(swiftvlc_frame_step_status_paused_for_retry.rawValue)
    case .noFrame:
      Int32(swiftvlc_frame_step_status_no_frame.rawValue)
    case .failed(let status):
      status
    }
  }
}

/// Attributes libVLC's untagged seek-end callback to the sole serialized
/// wrapper-issued native episode. Time events alone are not causal: ordinary
/// playback ticks can be delivered on either side of the native dispatch call.
final class NativeSeekMonitor: Sendable {
  fileprivate final class Attachment: Sendable {
    let context: NativeSeekContext
    let timelineGeneration: UInt64

    init(context: NativeSeekContext, timelineGeneration: UInt64) {
      self.context = context
      self.timelineGeneration = timelineGeneration
    }
  }

  /// Native attachment state is touched by main-actor commands and by the
  /// off-main teardown path. Keeping the handle, callback token, attachment
  /// flags, and invalidation bit under one lock prevents a command from reading
  /// an attached flag and then calling a handle teardown has already released.
  private struct LifecycleState: @unchecked Sendable {
    var player: OpaquePointer
    var contextOpaque: UnsafeMutableRawPointer?
    var isTimeAttached: Bool
    var isFrameEventAttached: Bool
    var invalidated = false
  }

  private let lifecycle: Mutex<LifecycleState>
  private let context: NativeSeekContext

  init(
    player: OpaquePointer,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64,
    emissionAuthority: NativeSeekEmissionAuthority
  ) {
    let context = NativeSeekContext(
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration,
      emissionAuthority: emissionAuthority
    )
    self.context = context
    let attachment = Attachment(
      context: context,
      timelineGeneration: context.currentTimelineGeneration()
    )
    let opaque = Unmanaged.passRetained(attachment).toOpaque()
    let isTimeAttached = Self.attachTime(to: player, opaque: opaque) == 0
    let isFrameEventAttached = swiftvlc_strict_frame_step_available()
      && Self.attachFrameEvent(to: player, opaque: opaque) == 0
    lifecycle = Mutex(LifecycleState(
      player: player,
      contextOpaque: opaque,
      isTimeAttached: isTimeAttached,
      isFrameEventAttached: isFrameEventAttached
    ))
  }

  deinit {
    invalidate()
  }

  func setHandler(_ handler: @escaping @Sendable (NativeSeekLanding) -> Void) {
    context.setHandler(handler)
  }

  func setSeekStartedHandler(_ handler: @escaping @Sendable (NativeSeekStart) -> Void) {
    context.setSeekStartedHandler(handler)
  }

  func setExternalSeekLandingHandler(
    _ handler: @escaping @Sendable (NativeExternalSeekLanding) -> Void
  ) {
    context.setExternalSeekLandingHandler(handler)
  }

  func setSeekEndedHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
    context.setSeekEndedHandler(handler)
  }

  func setSeekDrainAvailabilityHandler(_ handler: @escaping @Sendable () -> Void) {
    context.setSeekDrainAvailabilityHandler(handler)
  }

  func reserveCommand() -> UInt64 {
    context.reserveCommand()
  }

  var supportsVideoOutputEvidence: Bool {
    swiftvlc_libvlc_pip_extensions_version() >= 12
  }

  func requireVideoOutput(for token: UInt64) {
    context.requireVideoOutput(for: token)
  }

  func stageReservedCommandIfIdle(
    _ token: UInt64,
    expectedExternalEpoch: UInt64
  ) -> Bool {
    context.stageReservedCommandIfIdle(
      token,
      expectedExternalEpoch: expectedExternalEpoch
    )
  }

  func cancelReservedCommand(_ token: UInt64) {
    context.cancelReservedCommand(token)
  }

  func stageCommand() -> UInt64 {
    context.stageCommand()
  }

  func cancelStagedCommand(_ token: UInt64) {
    context.cancelStagedCommand(token)
  }

  func cancelCommand(_ token: UInt64) {
    context.cancelCommand(token)
  }

  /// Executes the exact native setter under a callback-stack ownership claim.
  /// Only a synchronous watcher start re-entering through this scope may claim
  /// the staged wrapper token.
  func withCausalSeekInvocation<Result>(
    token: UInt64,
    _ body: () throws -> Result
  )
    rethrows -> Result {
    let claim = NativeSeekInvocationClaim(
      context: ObjectIdentifier(context),
      token: token
    )
    return try NativeSeekInvocationAuthority.$current.withValue(claim) {
      try body()
    }
  }

  func consumeValidDispatchOwnership(
    _ token: UInt64,
    expectedExternalEpoch: UInt64
  ) -> Bool {
    context.consumeValidDispatchOwnership(
      token,
      expectedExternalEpoch: expectedExternalEpoch
    )
  }

  /// Consumes the exact watched landing reserved before callback-thread
  /// delivery hopped to MainActor. Handler payloads are wake-ups only.
  func consumeSeekLanding(token: UInt64) -> NativeSeekLanding? {
    context.consumeSeekLanding(token)
  }

  var seekEndedAwaitingPointToken: UInt64? {
    context.seekEndedAwaitingPointToken()
  }

  func setFrameHandler(_ handler: @escaping @Sendable (NativeFrameStepResult) -> Void) {
    context.setFrameHandler(handler)
  }

  /// Atomically consumes the exact callback-lane reservation. The result
  /// passed to the asynchronous handler is only a wake-up; consulting this
  /// slot makes duplicate or reordered MainActor tasks harmless.
  func consumeFrameResult(requestID: UInt64) -> NativeFrameStepResult? {
    context.consumeFrameResult(requestID: requestID)
  }

  func closeFrameResultLane() -> [NativeFrameStepResult] {
    context.closeFrameResultLane()
  }

  #if DEBUG
  var _frameResultAuthorityCountsForTesting:
    (reservations: Int, commitOwners: Int) {
    context.frameResultAuthorityCounts()
  }
  #endif

  func setFrameInvalidationHandler(
    _ handler: @escaping @Sendable (UInt64) -> Void
  ) {
    context.setFrameInvalidationHandler(handler)
  }

  func setFrameAvailabilityHandler(_ handler: @escaping @Sendable () -> Void) {
    context.setFrameAvailabilityHandler(handler)
  }

  var frameGeneration: UInt64 {
    context.currentFrameGeneration()
  }

  var externalSeekEpoch: UInt64 {
    context.currentExternalSeekEpoch()
  }

  var timelineGeneration: UInt64 {
    context.currentTimelineGeneration()
  }

  var hasSeekDrainPending: Bool {
    context.hasSeekDrainPending()
  }

  /// Version 4's timer watcher has no request ID. Keep this seam explicit so a
  /// future exact-ID v5 implementation can opt in without allowing sole-
  /// episode serialization to masquerade as exact native capability.
  var supportsExactSeekRequests: Bool {
    false
  }

  func requestFrameStep(
    requestID: UInt64,
    frameGeneration: UInt64
  ) -> NativeFrameRequestDispatch {
    lifecycle.withLock { lifecycle in
      guard !lifecycle.invalidated, lifecycle.isFrameEventAttached else {
        return .unavailable
      }
      guard
        context.reserveFrameRequest(
          requestID,
          frameGeneration: frameGeneration
        ) else { return .busy }
      let nativeResult = swiftvlc_media_player_request_next_frame_if_available(
        lifecycle.player,
        requestID
      )
      let disposition: NativeFrameRequestDispatch = switch nativeResult {
      case swiftvlc_next_frame_request_accepted:
        .accepted
      case swiftvlc_next_frame_request_busy:
        .busy
      case swiftvlc_next_frame_request_invalid,
           swiftvlc_next_frame_request_unavailable:
        .unavailable
      default:
        .unavailable
      }
      return context.finishFrameDispatch(
        requestID: requestID,
        disposition: disposition
      )
    }
  }

  /// Cancels only the exact strict request. `false` leaves its ID tombstoned:
  /// no subsequent command can enter the native slot until its terminal event
  /// or a documented timeline boundary drains it.
  @discardableResult
  func cancelFrameRequest(requestID: UInt64) -> Bool {
    lifecycle.withLock { lifecycle in
      let nativeCancelled = !lifecycle.invalidated
        && lifecycle.isFrameEventAttached
        && swiftvlc_media_player_cancel_next_frame_request_if_available(
          lifecycle.player,
          requestID
        )
      return context.finishFrameCancellation(
        requestID: requestID,
        nativeCancelled: nativeCancelled
      )
    }
  }

  func clearFrameQuarantineForCausalBoundary() {
    context.clearFrameQuarantineForCausalBoundary()
  }

  func commandAllowsPausedFallback(_ token: UInt64) -> Bool {
    context.commandAllowsPausedFallback(token)
  }

  func claimPausedFallback(_ landing: NativeSeekLanding) -> NativeSeekLanding? {
    context.claimPausedFallback(landing)
  }

  func reattach(
    to newPlayer: OpaquePointer,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64
  ) -> [NativeFrameStepResult] {
    replaceAttachment(
      on: newPlayer,
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration
    )
  }

  func invalidate() {
    lifecycle.withLock { lifecycle in
      guard !lifecycle.invalidated else { return }
      lifecycle.invalidated = true
      _ = context.closeFrameResultLane()
      context.setHandler(nil)
      context.setSeekStartedHandler(nil)
      context.setExternalSeekLandingHandler(nil)
      context.setSeekEndedHandler(nil)
      context.setSeekDrainAvailabilityHandler(nil)
      context.setFrameHandler(nil)
      context.setFrameInvalidationHandler(nil)
      context.setFrameAvailabilityHandler(nil)
      guard let contextOpaque = lifecycle.contextOpaque else { return }
      if lifecycle.isFrameEventAttached {
        Self.detachFrameEvent(from: lifecycle.player, opaque: contextOpaque)
        lifecycle.isFrameEventAttached = false
      }
      if lifecycle.isTimeAttached {
        libvlc_media_player_unwatch_time(lifecycle.player)
        lifecycle.isTimeAttached = false
      }
      lifecycle.contextOpaque = nil
      Unmanaged<Attachment>.fromOpaque(contextOpaque).release()
    }
  }

  func resetForTimelineReplacement(
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64
  ) -> [NativeFrameStepResult] {
    lifecycle.withLock { lifecycle in
      replaceAttachment(
        on: lifecycle.player,
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        lifecycle: &lifecycle
      )
    }
  }

  /// A watch attachment captures the media timeline it belongs to. Rotating
  /// the opaque attachment makes a callback that was already in flight before
  /// `unwatch_time` distinguishable from callbacks produced after a same-handle
  /// media replacement.
  private func replaceAttachment(
    on newPlayer: OpaquePointer,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64
  ) -> [NativeFrameStepResult] {
    lifecycle.withLock { lifecycle in
      replaceAttachment(
        on: newPlayer,
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        lifecycle: &lifecycle
      )
    }
  }

  private func replaceAttachment(
    on newPlayer: OpaquePointer,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64,
    lifecycle: inout LifecycleState
  ) -> [NativeFrameStepResult] {
    guard !lifecycle.invalidated, let oldOpaque = lifecycle.contextOpaque else {
      return []
    }
    if lifecycle.isFrameEventAttached {
      Self.detachFrameEvent(from: lifecycle.player, opaque: oldOpaque)
    }
    if lifecycle.isTimeAttached {
      libvlc_media_player_unwatch_time(lifecycle.player)
    }
    let reset = context.resetForTimelineReplacement(
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration
    )
    Unmanaged<Attachment>.fromOpaque(oldOpaque).release()
    let attachment = Attachment(
      context: context,
      timelineGeneration: reset.timelineGeneration
    )
    let newOpaque = Unmanaged.passRetained(attachment).toOpaque()
    lifecycle.player = newPlayer
    lifecycle.contextOpaque = newOpaque
    lifecycle.isTimeAttached = Self.attachTime(to: newPlayer, opaque: newOpaque) == 0
    lifecycle.isFrameEventAttached = swiftvlc_strict_frame_step_available()
      && Self.attachFrameEvent(to: newPlayer, opaque: newOpaque) == 0
    return reset.frameResults
  }

  private static func attachTime(
    to player: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) -> Int32 {
    if swiftvlc_libvlc_pip_extensions_version() >= 12 {
      return swiftvlc_libvlc_media_player_watch_time_with_video_output(
        player, 250_000, nativeSeekTimeUpdate, nil, nativeSeekStateChanged,
        nativeSeekVideoOutput, opaque
      )
    }
    return libvlc_media_player_watch_time(
      player,
      250_000,
      nativeSeekTimeUpdate,
      nil,
      nativeSeekStateChanged,
      opaque
    )
  }

  private static let frameEventType = Int32(libvlc_MediaPlayerFrameStepCompleted.rawValue)

  private static func attachFrameEvent(
    to player: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) -> Int32 {
    libvlc_event_attach(
      libvlc_media_player_event_manager(player),
      frameEventType,
      nativeFrameStepCompleted,
      opaque
    )
  }

  private static func detachFrameEvent(
    from player: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) {
    libvlc_event_detach(
      libvlc_media_player_event_manager(player),
      frameEventType,
      nativeFrameStepCompleted,
      opaque
    )
  }

  #if DEBUG
  var _seekLandingReservationCountForTesting: Int {
    context.seekLandingReservationCountForTesting()
  }

  var _timelineGenerationForTesting: UInt64 {
    context.currentTimelineGeneration()
  }

  func _noteSeekStartedForTesting(timelineGeneration: UInt64? = nil) {
    context.noteSeekStarted(
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration(),
      attribution: NativeSeekInvocationAuthority.token(for: context).map {
        .causalWrapper($0)
      } ?? .legacyTesting
    )
  }

  /// Explicit tokenless production-equivalent start for adversarial tests.
  /// Unlike the legacy helper above, this never consumes a staged reservation.
  func _noteExternalSeekStartedForTesting(timelineGeneration: UInt64? = nil) {
    context.noteSeekStarted(
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration(),
      attribution: .external
    )
  }

  func _noteSeekStartedForTesting(
    ifStagedToken token: UInt64,
    timelineGeneration: UInt64? = nil
  ) {
    context.noteSeekStarted(
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration(),
      attribution: .exactTesting(token)
    )
  }

  func _noteSeekEndedForTesting(timelineGeneration: UInt64? = nil) {
    context.noteSeekEnded(
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration()
    )
  }

  func _noteTimeUpdatedForTesting(
    timeMilliseconds: Int64,
    position: Double,
    timelineGeneration: UInt64? = nil
  ) {
    context.noteTimeUpdated(
      timeMicroseconds: timeMilliseconds >= 0 ? timeMilliseconds * 1000 : -1,
      position: position,
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration()
    )
  }

  func _noteVideoOutputForTesting(timeMilliseconds: Int64, position: Double, frameDurationMicroseconds: Int64 = 33333) {
    context.noteTimeUpdated(
      timeMicroseconds: timeMilliseconds * 1000, position: position,
      timelineGeneration: context.currentTimelineGeneration(),
      isVideoOutput: true, frameDurationMicroseconds: frameDurationMicroseconds
    )
  }

  func _requestFrameStepForTesting(
    requestID: UInt64,
    frameGeneration: UInt64,
    dispatch: () -> NativeFrameRequestDispatch
  ) -> NativeFrameRequestDispatch {
    guard
      context.reserveFrameRequest(
        requestID,
        frameGeneration: frameGeneration
      ) else { return .busy }
    let disposition = dispatch()
    return context.finishFrameDispatch(
      requestID: requestID,
      disposition: disposition
    )
  }

  @discardableResult
  func _cancelFrameStepForTesting(
    requestID: UInt64,
    cancel: () -> Bool
  ) -> Bool {
    context.finishFrameCancellation(
      requestID: requestID,
      nativeCancelled: cancel()
    )
  }

  func _noteFrameStepCompletedForTesting(
    requestID: UInt64,
    status: Int32,
    timeMicroseconds: Int64,
    position: Double
  ) {
    context.noteFrameResult(NativeFrameStepResult(
      token: requestID,
      status: status,
      timeMicroseconds: timeMicroseconds,
      position: position
    ))
  }
  #endif
}

private func nativeSeekTimeUpdate(
  _ point: UnsafePointer<libvlc_media_player_time_point_t>?,
  _ opaque: UnsafeMutableRawPointer?
) {
  guard let point, let opaque else { return }
  let attachment = Unmanaged<NativeSeekMonitor.Attachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  let timeMicroseconds = point.pointee.ts_us
  attachment.context.noteTimeUpdated(
    timeMicroseconds: timeMicroseconds,
    position: point.pointee.position,
    timelineGeneration: attachment.timelineGeneration
  )
}

private func nativeSeekVideoOutput(
  _ point: UnsafePointer<libvlc_media_player_time_point_t>?,
  _ durationMicroseconds: Int64,
  _ opaque: UnsafeMutableRawPointer?
) {
  guard let point, let opaque else { return }
  let attachment = Unmanaged<NativeSeekMonitor.Attachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  attachment.context.noteTimeUpdated(
    timeMicroseconds: point.pointee.ts_us,
    position: point.pointee.position,
    timelineGeneration: attachment.timelineGeneration,
    isVideoOutput: true,
    frameDurationMicroseconds: durationMicroseconds
  )
}

private func nativeFrameStepCompleted(
  _ event: UnsafePointer<libvlc_event_t>?,
  _ opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }
  let attachment = Unmanaged<NativeSeekMonitor.Attachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  let result = event.pointee.u.media_player_frame_step_completed
  attachment.context.noteFrameResult(NativeFrameStepResult(
    token: result.request_id,
    status: result.status,
    timeMicroseconds: result.time_us,
    position: Double(result.position)
  ))
}

private func nativeSeekStateChanged(
  _ point: UnsafePointer<libvlc_media_player_time_point_t>?,
  _ opaque: UnsafeMutableRawPointer?
) {
  guard let opaque else { return }
  let attachment = Unmanaged<NativeSeekMonitor.Attachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  if point == nil {
    attachment.context.noteSeekEnded(timelineGeneration: attachment.timelineGeneration)
  } else {
    let causalToken = NativeSeekInvocationAuthority.token(for: attachment.context)
    attachment.context.noteSeekStarted(
      timelineGeneration: attachment.timelineGeneration,
      attribution: causalToken.map { .causalWrapper($0) } ?? .external
    )
  }
}
