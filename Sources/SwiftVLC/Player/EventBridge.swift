import CLibVLC
import os
import Synchronization

/// Bridges libVLC C event callbacks to `AsyncStream<PlayerEvent>`.
///
/// Multi-consumer fan-out built on `Broadcaster<PlayerEvent>`. Each call
/// to `makeStream()` returns an independent `AsyncStream`. The C callback
/// reaches a retained callback context through an `Unmanaged` pointer
/// passed to libVLC's `event_attach`, then calls `broadcast(_:)` which
/// snapshots subscribers under a Mutex and yields outside the lock.
final class EventBridge: Sendable {
  private nonisolated(unsafe) var eventManager: OpaquePointer
  private let context: EventBridgeCallbackContext
  private nonisolated(unsafe) var attachmentOpaque: UnsafeMutableRawPointer?
  private nonisolated(unsafe) var attachedEventTypes: [Int32]
  private let nativeHandleGeneration = Mutex<UInt64>(1)
  private let invalidated = Mutex(false)

  init(eventManager: OpaquePointer, endCoordinator: PlaybackEndCoordinator) {
    self.eventManager = eventManager

    let context = EventBridgeCallbackContext(endCoordinator: endCoordinator)
    self.context = context
    let attachment = EventBridgeCallbackAttachment(
      context: context,
      nativeHandleGeneration: 1
    )
    let opaque = Unmanaged.passRetained(attachment).toOpaque()
    attachmentOpaque = opaque

    attachedEventTypes = Self.attachEvents(to: eventManager, opaque: opaque)
  }

  deinit {
    invalidate()
  }

  /// Detaches all event listeners and finishes all streams.
  /// Safe to call multiple times (idempotent). Must be called while
  /// the event manager's parent (media player) is still alive.
  func invalidate() {
    let shouldCleanUp = invalidated.withLock { alreadyDone -> Bool in
      guard !alreadyDone else { return false }
      alreadyDone = true
      return true
    }
    guard shouldCleanUp else { return }

    guard let attachmentOpaque else { return }
    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: attachmentOpaque)
    attachedEventTypes = []
    self.attachmentOpaque = nil
    // `libvlc_event_detach` takes the same event-manager lock that surrounds
    // callback execution. Once every detach returns, no callback can still be
    // borrowing this attachment token, so releasing it here is safe.
    Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(attachmentOpaque).release()
    // `terminate()`, not `finishAll()`: invalidation is permanent. The
    // mid-life native handle swap goes through `reattach(to:)` and never
    // lands here, so the only callers are shutdown and deinit — after which
    // the event source is gone for good. `Player.events` is a computed
    // property that subscribes per access, so `finishAll()` would hand a
    // post-shutdown caller a live stream that never finishes.
    context.terminate()
  }

  /// Moves the existing streams to a replacement native media player.
  ///
  /// `Player` recreates its libVLC handle after a stopped drawable-backed
  /// playback because libVLC keeps a "free vout" whose iOS window provider
  /// still points at the previous UIView. The Swift `Player.events` stream must
  /// survive that native-handle swap, so this detaches callbacks from the previous
  /// event manager and attaches the same broadcaster to the new one.
  @discardableResult
  func reattach(to newEventManager: OpaquePointer) -> UInt64 {
    let isInvalidated = invalidated.withLock { $0 }
    guard !isInvalidated, let oldAttachmentOpaque = attachmentOpaque else {
      return nativeHandleGeneration.withLock { $0 }
    }

    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: oldAttachmentOpaque)
    Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(oldAttachmentOpaque).release()

    // The retiring handle cannot emit after detach returns. Clear its pending
    // terminal classification before the successor is attached, so neither an
    // old late callback nor an early successor callback can cross the reset.
    context.endCoordinator.clearForHandleReplacement()
    context.clearPendingStopForNativeHandleReplacement()

    let generation = nativeHandleGeneration.withLock { generation in
      precondition(generation < UInt64.max, "Native handle generation exhausted")
      generation += 1
      return generation
    }
    let attachment = EventBridgeCallbackAttachment(
      context: context,
      nativeHandleGeneration: generation
    )
    let newAttachmentOpaque = Unmanaged.passRetained(attachment).toOpaque()
    eventManager = newEventManager
    attachmentOpaque = newAttachmentOpaque
    attachedEventTypes = Self.attachEvents(to: newEventManager, opaque: newAttachmentOpaque)
    return generation
  }

  /// Monotonic identity of the native player currently feeding this bridge.
  /// Unlike a pointer address, it cannot alias a retired A handle after an
  /// allocator reuses that address for a later C handle.
  var currentNativeHandleGeneration: UInt64 {
    nativeHandleGeneration.withLock { $0 }
  }

  var currentNativePlayerGeneration: NativePlayerGeneration {
    NativePlayerGeneration(currentNativeHandleGeneration)
  }

  /// Playback generation already accepted by the callback lane, which can be
  /// ahead of the main actor while a native media-change event is queued.
  var currentPlaybackGeneration: UInt64 {
    context.currentPlaybackGeneration
  }

  /// Runs a main-actor mutation only if the callback lane is still on the
  /// expected playback generation. The comparison and mutation share the
  /// callback lane's lifecycle lock, giving callers a real linearization point
  /// against a concurrent native media-change callback.
  @MainActor
  func performIfCurrentPlaybackGeneration(
    _ expectedGeneration: UInt64,
    _ mutation: () -> Void
  ) -> Bool {
    context.performIfCurrentPlaybackGeneration(expectedGeneration, mutation)
  }

  /// Creates a new independent `AsyncStream` for consuming player events.
  /// Each stream is offered events broadcast after creation that pass its
  /// filter. Delivery under consumer lag follows `policy`.
  func makeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEvent) -> Bool)?
  ) -> AsyncStream<PlayerEvent> {
    context.makeStream(policy: policy, filter: filter)
  }

  func makeSourcedStream(policy: EventBufferingPolicy) -> AsyncStream<SourcedPlayerEvent> {
    context.makeSourcedStream(policy: policy)
  }

  func makeEnvelopeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEventEnvelope) -> Bool)?
  ) -> AsyncStream<PlayerEventEnvelope> {
    context.makeEnvelopeStream(policy: policy, filter: filter)
  }

  func makeTerminalOutcomeStream() -> AsyncStream<PlaybackTerminalOutcome> {
    context.makeTerminalOutcomeStream()
  }

  /// Aligns the event bridge with a wrapper-initiated media generation.
  /// The outgoing generation is frozen as a replacement before the new
  /// timeline becomes current.
  @discardableResult
  func synchronizePlaybackGeneration(
    _ generation: UInt64,
    media: OpaquePointer?,
    outgoingNativeHandleGeneration: UInt64? = nil
  ) -> UInt64 {
    context.synchronizePlaybackGeneration(
      generation,
      media: media,
      nativeHandleGeneration: outgoingNativeHandleGeneration
        ?? currentNativeHandleGeneration,
      retiringNativeHandle: outgoingNativeHandleGeneration != nil
    )
  }

  /// Records that the current generation is expected to stop because the
  /// wrapper issued an explicit stop request.
  func markRequestedStop(playbackGeneration: UInt64) {
    context.markRequestedStop(playbackGeneration: playbackGeneration)
  }

  /// Records timeline facts learned synchronously by the wrapper rather than
  /// through a native player event.
  func updateKnownDuration(_ duration: Duration?, playbackGeneration: UInt64) {
    context.updateKnownDuration(duration, playbackGeneration: playbackGeneration)
  }

  /// Records an accepted seek or frame step immediately, including while the
  /// native event thread is quiescent because playback is paused.
  func updateAuthoritativeTimeline(
    time: Duration,
    position: Double?,
    playbackGeneration: UInt64
  ) {
    context.updateAuthoritativeTimeline(
      time: time,
      position: position,
      playbackGeneration: playbackGeneration
    )
  }

  /// Ends the current generation without waiting for another native event.
  /// Used when shutdown or native-handle retirement makes future callbacks
  /// unobservable by construction.
  func finishCurrentPlaybackGeneration(
    cause: PlaybackTerminalCause,
    playbackGeneration: UInt64
  ) {
    context.finishPlaybackGeneration(
      playbackGeneration,
      cause: cause,
      nativeHandleGeneration: currentNativeHandleGeneration
    )
  }

  /// Marks a new authoritative timeline. Clock samples emitted before this
  /// point carry a lower revision and are discarded by the consumer.
  @discardableResult
  func advanceTimelineRevision() -> UInt64 {
    context.advanceTimelineRevision()
  }

  /// Pushes an event through the same fan-out path the C callback uses,
  /// including subscription buffering — unlike
  /// `Player._handleEventForTesting`, which bypasses the bridge entirely.
  func _broadcastForTesting(
    _ event: PlayerEvent,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64? = nil
  ) {
    context.broadcast(
      event,
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration
    )
  }

  /// Exercises the complete native callback ordering with a synthetic event.
  func _emitNativeEventForTesting(_ event: libvlc_event_t) {
    guard let attachmentOpaque else { return }
    withUnsafePointer(to: event) { event in
      playerEventCallback(event: event, opaque: attachmentOpaque)
    }
  }

  static let playerEventTypes: [Int32] = [
    libvlc_MediaPlayerMediaChanged,
    libvlc_MediaPlayerNothingSpecial,
    libvlc_MediaPlayerOpening,
    libvlc_MediaPlayerBuffering,
    libvlc_MediaPlayerPlaying,
    libvlc_MediaPlayerPaused,
    libvlc_MediaPlayerStopped,
    libvlc_MediaPlayerStopping,
    libvlc_MediaPlayerMediaStopping,
    libvlc_MediaPlayerEncounteredError,
    libvlc_MediaPlayerTimeChanged,
    libvlc_MediaPlayerPositionChanged,
    libvlc_MediaPlayerSeekableChanged,
    libvlc_MediaPlayerPausableChanged,
    libvlc_MediaPlayerLengthChanged,
    libvlc_MediaPlayerVout,
    libvlc_MediaPlayerESAdded,
    libvlc_MediaPlayerESDeleted,
    libvlc_MediaPlayerESSelected,
    libvlc_MediaPlayerESUpdated,
    libvlc_MediaPlayerCorked,
    libvlc_MediaPlayerUncorked,
    libvlc_MediaPlayerMuted,
    libvlc_MediaPlayerUnmuted,
    libvlc_MediaPlayerAudioVolume,
    libvlc_MediaPlayerAudioDevice,
    libvlc_MediaPlayerChapterChanged,
    libvlc_MediaPlayerRecordChanged,
    libvlc_MediaPlayerTitleListChanged,
    libvlc_MediaPlayerTitleSelectionChanged,
    libvlc_MediaPlayerSnapshotTaken,
    libvlc_MediaPlayerProgramAdded,
    libvlc_MediaPlayerProgramDeleted,
    libvlc_MediaPlayerProgramSelected,
    libvlc_MediaPlayerProgramUpdated
  ].map { Int32($0.rawValue) }

  private static func attachEvents(
    to eventManager: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) -> [Int32] {
    var attachedEventTypes: [Int32] = []
    for eventType in playerEventTypes
      where libvlc_event_attach(eventManager, eventType, playerEventCallback, opaque) == 0 {
      attachedEventTypes.append(eventType)
    }
    return attachedEventTypes
  }

  private static func detachEvents(
    _ eventTypes: [Int32],
    from eventManager: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) {
    for eventType in eventTypes {
      libvlc_event_detach(eventManager, eventType, playerEventCallback, opaque)
    }
  }
}

struct SourcedPlayerEvent {
  let nativeHandleGeneration: UInt64
  let playbackGeneration: UInt64
  let event: PlayerEvent
  /// The timeline revision current when libVLC emitted this event.
  ///
  /// An accepted seek advances the revision, so a clock sample produced
  /// before it carries a lower value and can be discarded instead of
  /// overwriting the seek target. Defaults to zero, which is never newer
  /// than an accepted seek, so a directly-constructed event is treated as
  /// pre-seek rather than silently authoritative.
  let timelineRevision: UInt64

  init(
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64,
    event: PlayerEvent,
    timelineRevision: UInt64 = 0
  ) {
    self.nativeHandleGeneration = nativeHandleGeneration
    self.playbackGeneration = playbackGeneration
    self.event = event
    self.timelineRevision = timelineRevision
  }
}

/// Immutable identity and shared fan-out context for one native attachment.
/// A fresh retained token is passed to libVLC on every handle replacement;
/// callbacks can therefore never acquire a successor's generation by reading
/// mutable shared state after they were emitted by a predecessor.
private final class EventBridgeCallbackAttachment: Sendable {
  let context: EventBridgeCallbackContext
  let nativeHandleGeneration: UInt64

  init(context: EventBridgeCallbackContext, nativeHandleGeneration: UInt64) {
    self.context = context
    self.nativeHandleGeneration = nativeHandleGeneration
  }
}

private final class EventBridgeCallbackContext: Sendable {
  private let events = Broadcaster<PlayerEvent>(defaultBufferSize: 64)
  private let eventEnvelopes = Broadcaster<PlayerEventEnvelope>(defaultBufferSize: 64)
  private let sourcedEvents = Broadcaster<SourcedPlayerEvent>(defaultBufferSize: 64)
  private let terminalOutcomes = Broadcaster<PlaybackTerminalOutcome>(defaultBufferSize: 16)
  /// Stamped onto every sourced event so the consumer can tell clock samples
  /// that predate an accepted seek from ones that follow it. Lives here
  /// because the stamp has to be taken on libVLC's thread, at emission.
  private let timelineRevision = Mutex<UInt64>(0)
  private struct TimelineSnapshot: Sendable {
    var time: Duration = .zero
    var duration: Duration?
    var position: Double = 0
    var bufferFill: Float = 0
    var activeVideoOutputs = 0

    var publicValue: PlaybackFinalTimeline {
      PlaybackFinalTimeline(
        time: time,
        duration: duration,
        position: position,
        bufferFill: bufferFill,
        activeVideoOutputs: activeVideoOutputs
      )
    }
  }

  private struct PlaybackLifecycleState: Sendable {
    var currentGeneration: UInt64 = 0
    var currentMediaIdentity: UInt?
    var mediaGenerations: [UInt: UInt64] = [:]
    /// Wrapper-initiated `set_media` calls echo through `MediaChanged`. This
    /// token distinguishes that echo from an external change which happens to
    /// reuse the same media pointer.
    var pendingWrapperMediaChangedGeneration: UInt64?
    /// Retired generations awaiting their ordered `MediaStopping` callback
    /// when the successor reuses the exact same retained media pointer.
    var retiredMediaGenerations: [UInt: [UInt64]] = [:]
    var snapshots: [UInt64: TimelineSnapshot] = [:]
    var terminalIntents: [UInt64: PlaybackTerminalCause] = [:]
    var lastEmittedGeneration: UInt64 = 0
    var pendingStoppedGeneration: UInt64?
  }

  private let playbackLifecycle = Mutex(PlaybackLifecycleState())
  let endCoordinator: PlaybackEndCoordinator

  init(endCoordinator: PlaybackEndCoordinator) {
    self.endCoordinator = endCoordinator
  }

  func makeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEvent) -> Bool)?
  ) -> AsyncStream<PlayerEvent> {
    events.subscribe(policy: policy, filter: filter)
  }

  func makeSourcedStream(policy: EventBufferingPolicy) -> AsyncStream<SourcedPlayerEvent> {
    sourcedEvents.subscribe(policy: policy)
  }

  func makeEnvelopeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEventEnvelope) -> Bool)?
  ) -> AsyncStream<PlayerEventEnvelope> {
    eventEnvelopes.subscribe(policy: policy, filter: filter)
  }

  func makeTerminalOutcomeStream() -> AsyncStream<PlaybackTerminalOutcome> {
    terminalOutcomes.subscribe(policy: .unbounded)
  }

  func synchronizePlaybackGeneration(
    _ generation: UInt64,
    media: OpaquePointer?,
    nativeHandleGeneration: UInt64,
    retiringNativeHandle: Bool
  ) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      let outgoing = state.currentGeneration
      let outgoingIdentity = state.currentMediaIdentity
      let outcome = makeOutcome(
        in: &state,
        generation: outgoing,
        cause: state.terminalIntents[outgoing] ?? .replacement,
        nativeHandleGeneration: nativeHandleGeneration
      )
      precondition(state.currentGeneration < UInt64.max, "Playback generation exhausted")
      let adoptedGeneration = max(generation, state.currentGeneration + 1)
      state.currentGeneration = adoptedGeneration
      state.currentMediaIdentity = Self.identity(of: media)
      state.pendingWrapperMediaChangedGeneration = adoptedGeneration
      if let identity = state.currentMediaIdentity {
        if
          !retiringNativeHandle,
          outcome != nil,
          outgoing > 0,
          identity == outgoingIdentity {
          state.retiredMediaGenerations[identity, default: []].append(outgoing)
        }
        state.mediaGenerations[identity] = adoptedGeneration
      }
      state.snapshots[adoptedGeneration] = TimelineSnapshot()
      return (adoptedGeneration, outcome)
    }
    if let outcome = result.1 {
      terminalOutcomes.broadcast(outcome)
    }
    return result.0
  }

  func markRequestedStop(playbackGeneration: UInt64) {
    playbackLifecycle.withLock { state in
      guard playbackGeneration > state.lastEmittedGeneration else { return }
      state.terminalIntents[playbackGeneration] = .requestedStop
      state.pendingStoppedGeneration = playbackGeneration
      // An explicit stop applies to the session the caller can currently see.
      // Prefer it over an unresolved same-pointer replacement callback; a late
      // retiring callback is harmless because this generation is now ending
      // too, while attributing the requested stop to the retired generation
      // would leave the current one without an outcome.
      if
        playbackGeneration == state.currentGeneration,
        let identity = state.currentMediaIdentity {
        state.retiredMediaGenerations[identity] = nil
      }
    }
  }

  func updateKnownDuration(_ duration: Duration?, playbackGeneration: UInt64) {
    playbackLifecycle.withLock { state in
      guard
        playbackGeneration == state.currentGeneration,
        playbackGeneration > state.lastEmittedGeneration
      else { return }
      var snapshot = state.snapshots[playbackGeneration] ?? TimelineSnapshot()
      snapshot.duration = duration
      state.snapshots[playbackGeneration] = snapshot
    }
  }

  func updateAuthoritativeTimeline(
    time: Duration,
    position: Double?,
    playbackGeneration: UInt64
  ) {
    playbackLifecycle.withLock { state in
      guard
        playbackGeneration == state.currentGeneration,
        playbackGeneration > state.lastEmittedGeneration
      else { return }
      var snapshot = state.snapshots[playbackGeneration] ?? TimelineSnapshot()
      snapshot.time = time
      if let position {
        snapshot.position = position
      }
      state.snapshots[playbackGeneration] = snapshot
    }
  }

  func finishPlaybackGeneration(
    _ generation: UInt64,
    cause: PlaybackTerminalCause,
    nativeHandleGeneration: UInt64
  ) {
    let outcome = playbackLifecycle.withLock { state in
      makeOutcome(
        in: &state,
        generation: generation,
        cause: state.terminalIntents[generation] ?? cause,
        nativeHandleGeneration: nativeHandleGeneration
      )
    }
    if let outcome {
      terminalOutcomes.broadcast(outcome)
    }
  }

  func broadcast(
    _ event: PlayerEvent,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64? = nil
  ) {
    let playbackGeneration = playbackGeneration ?? currentPlaybackGeneration
    recordTimeline(event, generation: playbackGeneration)
    // Each broadcaster is gated on its own emptiness so a libVLC event
    // with no consumers costs neither the lock-and-snapshot nor the
    // sourced-wrapper construction. The sourced broadcast (the player's
    // internal observable mirror; never carries user filters) runs
    // first, so a slow user filter on the public stream can only delay
    // public delivery — internal state is already on its way.
    if !sourcedEvents.isEmpty {
      sourcedEvents.broadcast(
        SourcedPlayerEvent(
          nativeHandleGeneration: nativeHandleGeneration,
          playbackGeneration: playbackGeneration,
          event: event,
          timelineRevision: timelineRevision.withLock { $0 }
        )
      )
    }
    if !eventEnvelopes.isEmpty {
      eventEnvelopes.broadcast(
        PlayerEventEnvelope(
          event: event,
          nativeGeneration: NativePlayerGeneration(nativeHandleGeneration),
          playbackGeneration: PlaybackGeneration(playbackGeneration)
        )
      )
    }
    if !events.isEmpty {
      events.broadcast(event)
    }
  }

  func advanceTimelineRevision() -> UInt64 {
    timelineRevision.withLock { revision in
      revision &+= 1
      return revision
    }
  }

  /// Permanently closes both broadcasters, so streams handed out after this
  /// point are already finished rather than waiting on a source that will
  /// never emit again.
  func terminate() {
    events.terminate()
    eventEnvelopes.terminate()
    sourcedEvents.terminate()
    terminalOutcomes.terminate()
  }

  var currentPlaybackGeneration: UInt64 {
    playbackLifecycle.withLock { $0.currentGeneration }
  }

  @MainActor
  func performIfCurrentPlaybackGeneration(
    _ expectedGeneration: UInt64,
    _ mutation: () -> Void
  ) -> Bool {
    playbackLifecycle.withLock { state in
      guard state.currentGeneration == expectedGeneration else { return false }
      mutation()
      return true
    }
  }

  func noteExternalMediaChanged(
    _ media: OpaquePointer?,
    nativeHandleGeneration: UInt64
  ) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      let identity = Self.identity(of: media)
      if
        state.pendingWrapperMediaChangedGeneration == state.currentGeneration,
        identity == state.currentMediaIdentity {
        state.pendingWrapperMediaChangedGeneration = nil
        return (state.currentGeneration, nil)
      }
      state.pendingWrapperMediaChangedGeneration = nil
      let outgoing = state.currentGeneration
      let outgoingIdentity = state.currentMediaIdentity
      let outcome = makeOutcome(
        in: &state,
        generation: outgoing,
        cause: state.terminalIntents[outgoing] ?? .replacement,
        nativeHandleGeneration: nativeHandleGeneration
      )
      precondition(state.currentGeneration < UInt64.max, "Playback generation exhausted")
      state.currentGeneration += 1
      state.currentMediaIdentity = identity
      if let identity {
        if outcome != nil, outgoing > 0, identity == outgoingIdentity {
          state.retiredMediaGenerations[identity, default: []].append(outgoing)
        }
        state.mediaGenerations[identity] = state.currentGeneration
      }
      state.snapshots[state.currentGeneration] = TimelineSnapshot()
      return (state.currentGeneration, outcome)
    }
    if let outcome = result.1 {
      terminalOutcomes.broadcast(outcome)
    }
    return result.0
  }

  func noteMediaStopping(
    media: OpaquePointer?,
    reason: libvlc_stopping_reason_t,
    nativeHandleGeneration: UInt64
  ) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      let identity = Self.identity(of: media)
      let generation: UInt64
      if
        let identity,
        var retired = state.retiredMediaGenerations[identity],
        !retired.isEmpty {
        generation = retired.removeFirst()
        state.retiredMediaGenerations[identity] = retired.isEmpty ? nil : retired
      } else {
        generation = identity.flatMap { state.mediaGenerations[$0] }
          ?? state.currentGeneration
      }
      state.pendingStoppedGeneration = generation
      let engineCause: PlaybackTerminalCause = switch reason {
      case libvlc_stopping_reason_eos: .naturalEnd
      case libvlc_stopping_reason_user: .requestedStop
      case libvlc_stopping_reason_error: .failure(.unknown)
      default: .unknownNativeStop
      }
      let outcome = makeOutcome(
        in: &state,
        generation: generation,
        cause: state.terminalIntents[generation] ?? engineCause,
        nativeHandleGeneration: nativeHandleGeneration
      )
      return (generation, outcome)
    }
    if let outcome = result.1 {
      terminalOutcomes.broadcast(outcome)
    }
    return result.0
  }

  func noteEncounteredError(nativeHandleGeneration: UInt64) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      let generation = state.currentGeneration
      state.terminalIntents[generation] = .failure(.unknown)
      let outcome = makeOutcome(
        in: &state,
        generation: generation,
        cause: .failure(.unknown),
        nativeHandleGeneration: nativeHandleGeneration
      )
      return (generation, outcome)
    }
    if let outcome = result.1 {
      terminalOutcomes.broadcast(outcome)
    }
    return result.0
  }

  func consumeStoppedGeneration(nativeHandleGeneration: UInt64) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      let generation = state.pendingStoppedGeneration ?? state.currentGeneration
      state.pendingStoppedGeneration = nil
      let outcome = makeOutcome(
        in: &state,
        generation: generation,
        cause: state.terminalIntents[generation] ?? .unknownNativeStop,
        nativeHandleGeneration: nativeHandleGeneration
      )
      return (generation, outcome)
    }
    if let outcome = result.1 {
      terminalOutcomes.broadcast(outcome)
    }
    return result.0
  }

  func noteCurrentGenerationProgress(_ generation: UInt64) {
    playbackLifecycle.withLock { state in
      if generation == state.currentGeneration, let identity = state.currentMediaIdentity {
        // Native callbacks are serialized. Once the successor opens or plays,
        // every stopping callback ordered before that progress has arrived, so
        // an unresolved same-pointer retirement can no longer be consumed by a
        // future stop belonging to the successor.
        state.retiredMediaGenerations[identity] = nil
      }
      if generation == state.currentGeneration {
        state.pendingWrapperMediaChangedGeneration = nil
      }
      if
        let pending = state.pendingStoppedGeneration,
        pending < generation,
        pending <= state.lastEmittedGeneration {
        state.pendingStoppedGeneration = nil
      }
    }
  }

  func clearPendingStopForNativeHandleReplacement() {
    playbackLifecycle.withLock { state in
      state.pendingStoppedGeneration = nil
      state.pendingWrapperMediaChangedGeneration = nil
      state.retiredMediaGenerations.removeAll()
    }
  }

  private func recordTimeline(_ event: PlayerEvent, generation: UInt64) {
    guard generation > 0 else { return }
    playbackLifecycle.withLock { state in
      var snapshot = state.snapshots[generation] ?? TimelineSnapshot()
      switch event {
      case .timeChanged(let time): snapshot.time = time
      case .lengthChanged(let duration): snapshot.duration = duration
      case .positionChanged(let position): snapshot.position = position
      case .bufferingProgress(let fill): snapshot.bufferFill = fill
      case .voutChanged(let count): snapshot.activeVideoOutputs = count
      default: break
      }
      state.snapshots[generation] = snapshot
    }
  }

  private func makeOutcome(
    in state: inout PlaybackLifecycleState,
    generation: UInt64,
    cause: PlaybackTerminalCause,
    nativeHandleGeneration: UInt64
  ) -> PlaybackTerminalOutcome? {
    guard generation > state.lastEmittedGeneration else { return nil }
    state.lastEmittedGeneration = generation
    let snapshot = state.snapshots[generation] ?? TimelineSnapshot()
    state.terminalIntents[generation] = nil
    state.snapshots = state.snapshots.filter { $0.key >= generation }
    state.mediaGenerations = state.mediaGenerations.filter { $0.value >= generation }
    return PlaybackTerminalOutcome(
      generation: PlaybackGeneration(generation),
      nativeGeneration: NativePlayerGeneration(nativeHandleGeneration),
      cause: cause,
      finalTimeline: snapshot.publicValue
    )
  }

  private static func identity(of media: OpaquePointer?) -> UInt? {
    media.map { UInt(bitPattern: $0) }
  }
}

// MARK: - C Callback (free function)

/// Free function invoked on libVLC's internal event thread.
/// `AsyncStream.Continuation.yield` is documented safe from any thread.
private func playerEventCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let interval = Signposts.signposter.beginInterval("EventBridge.callback")
  defer { Signposts.signposter.endInterval("EventBridge.callback", interval) }

  let attachment = Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  let context = attachment.context

  guard let mapped = mapEvent(event.pointee) else { return }
  let coordinator = context.endCoordinator
  // Record every terminal fact before exposing its raw event. Public filters
  // run synchronously on this thread and may issue player commands, so doing
  // this after broadcast lets reentrant work classify the stop without the
  // engine's authoritative cause.
  let playbackGeneration: UInt64
  let shouldSynthesizeEnd: Bool
  switch mapped {
  case .mediaChanged:
    playbackGeneration = context.noteExternalMediaChanged(
      event.pointee.u.media_player_media_changed.new_media,
      nativeHandleGeneration: attachment.nativeHandleGeneration
    )
    shouldSynthesizeEnd = false

  case .mediaStopping:
    let stopping = event.pointee.u.media_player_media_stopping
    coordinator.noteStoppingReason(stopping.reason)
    playbackGeneration = context.noteMediaStopping(
      media: stopping.media,
      reason: stopping.reason,
      nativeHandleGeneration: attachment.nativeHandleGeneration
    )
    shouldSynthesizeEnd = false

  case .encounteredError:
    playbackGeneration = context.noteEncounteredError(
      nativeHandleGeneration: attachment.nativeHandleGeneration
    )
    shouldSynthesizeEnd = false

  case .stateChanged(.stopped):
    playbackGeneration = context.consumeStoppedGeneration(
      nativeHandleGeneration: attachment.nativeHandleGeneration
    )
    shouldSynthesizeEnd = coordinator.consumeStoppedShouldSynthesizeEnd()

  case .stateChanged(.opening), .stateChanged(.playing):
    playbackGeneration = context.currentPlaybackGeneration
    context.noteCurrentGenerationProgress(playbackGeneration)
    shouldSynthesizeEnd = false

  default:
    playbackGeneration = context.currentPlaybackGeneration
    shouldSynthesizeEnd = false
  }

  // Both emissions are made from the same immutable attachment token. Every
  // subscriber therefore observes `.stopped` then `.endReached` with one
  // generation, independent of consumer lag or native pointer reuse.
  context.broadcast(
    mapped,
    nativeHandleGeneration: attachment.nativeHandleGeneration,
    playbackGeneration: playbackGeneration
  )
  if shouldSynthesizeEnd {
    context.broadcast(
      .endReached,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      playbackGeneration: playbackGeneration
    )
  }
}

/// Maps a single libVLC `libvlc_event_t` to a typed `PlayerEvent`.
///
/// Internal rather than `private` so unit tests can synthesize each
/// event variant with hand-built `libvlc_event_t` values. Most of
/// these events don't fire in a headless test environment, so full
/// switch coverage is impossible without direct invocation.
func mapEvent(_ event: libvlc_event_t) -> PlayerEvent? {
  let type = libvlc_event_e(rawValue: UInt32(event.type))

  switch type {
  case libvlc_MediaPlayerNothingSpecial:
    return .stateChanged(.idle)

  case libvlc_MediaPlayerOpening:
    return .stateChanged(.opening)

  case libvlc_MediaPlayerBuffering:
    let pct = event.u.media_player_buffering.new_cache / 100.0
    return .bufferingProgress(pct)

  case libvlc_MediaPlayerPlaying:
    return .stateChanged(.playing)

  case libvlc_MediaPlayerPaused:
    return .stateChanged(.paused)

  case libvlc_MediaPlayerStopped:
    return .stateChanged(.stopped)

  case libvlc_MediaPlayerStopping:
    return .stateChanged(.stopping)

  case libvlc_MediaPlayerEncounteredError:
    return .encounteredError

  case libvlc_MediaPlayerTimeChanged:
    let ms = event.u.media_player_time_changed.new_time
    return .timeChanged(.milliseconds(ms))

  case libvlc_MediaPlayerPositionChanged:
    let pos = event.u.media_player_position_changed.new_position
    return .positionChanged(pos)

  case libvlc_MediaPlayerSeekableChanged:
    let seekable = event.u.media_player_seekable_changed.new_seekable != 0
    return .seekableChanged(seekable)

  case libvlc_MediaPlayerPausableChanged:
    let pausable = event.u.media_player_pausable_changed.new_pausable != 0
    return .pausableChanged(pausable)

  case libvlc_MediaPlayerLengthChanged:
    let ms = event.u.media_player_length_changed.new_length
    return .lengthChanged(.milliseconds(ms))

  case libvlc_MediaPlayerVout:
    let count = event.u.media_player_vout.new_count
    return .voutChanged(Int(count))

  case libvlc_MediaPlayerESAdded,
       libvlc_MediaPlayerESDeleted,
       libvlc_MediaPlayerESSelected,
       libvlc_MediaPlayerESUpdated:
    return .tracksChanged

  case libvlc_MediaPlayerMediaChanged:
    return .mediaChanged

  case libvlc_MediaPlayerMuted:
    return .muted

  case libvlc_MediaPlayerUnmuted:
    return .unmuted

  case libvlc_MediaPlayerCorked:
    return .corked

  case libvlc_MediaPlayerUncorked:
    return .uncorked

  case libvlc_MediaPlayerAudioVolume:
    let vol = event.u.media_player_audio_volume.volume
    return .volumeChanged(vol)

  case libvlc_MediaPlayerAudioDevice:
    let device = event.u.media_player_audio_device.device.map { String(cString: $0) }
    return .audioDeviceChanged(device)

  case libvlc_MediaPlayerMediaStopping:
    return .mediaStopping

  case libvlc_MediaPlayerChapterChanged:
    let chapter = event.u.media_player_chapter_changed.new_chapter
    return .chapterChanged(Int(chapter))

  case libvlc_MediaPlayerRecordChanged:
    let recording = event.u.media_player_record_changed.recording
    let path = event.u.media_player_record_changed.recorded_file_path
      .map { String(cString: $0) }
    return .recordingChanged(isRecording: recording, filePath: path)

  case libvlc_MediaPlayerTitleListChanged:
    return .titleListChanged

  case libvlc_MediaPlayerTitleSelectionChanged:
    let index = event.u.media_player_title_selection_changed.index
    return .titleSelectionChanged(Int(index))

  case libvlc_MediaPlayerSnapshotTaken:
    let path = String(cString: event.u.media_player_snapshot_taken.psz_filename)
    return .snapshotTaken(path)

  case libvlc_MediaPlayerProgramAdded:
    let id = event.u.media_player_program_changed.i_id
    return .programAdded(Int(id))

  case libvlc_MediaPlayerProgramDeleted:
    let id = event.u.media_player_program_changed.i_id
    return .programDeleted(Int(id))

  case libvlc_MediaPlayerProgramSelected:
    let unselected = event.u.media_player_program_selection_changed.i_unselected_id
    let selected = event.u.media_player_program_selection_changed.i_selected_id
    return .programSelected(unselectedId: Int(unselected), selectedId: Int(selected))

  case libvlc_MediaPlayerProgramUpdated:
    let id = event.u.media_player_program_changed.i_id
    return .programUpdated(Int(id))

  default:
    return nil
  }
}
