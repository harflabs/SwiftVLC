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

  /// Marks a new authoritative timeline. Clock samples emitted before this
  /// point carry a lower revision and are discarded by the consumer.
  @discardableResult
  func advanceTimelineRevision() -> UInt64 {
    context.advanceTimelineRevision()
  }

  /// Pushes an event through the same fan-out path the C callback uses,
  /// including subscription buffering — unlike
  /// `Player._handleEventForTesting`, which bypasses the bridge entirely.
  func _broadcastForTesting(_ event: PlayerEvent, nativeHandleGeneration: UInt64) {
    context.broadcast(event, nativeHandleGeneration: nativeHandleGeneration)
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
    event: PlayerEvent,
    timelineRevision: UInt64 = 0
  ) {
    self.nativeHandleGeneration = nativeHandleGeneration
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
  private let sourcedEvents = Broadcaster<SourcedPlayerEvent>(defaultBufferSize: 64)
  /// Stamped onto every sourced event so the consumer can tell clock samples
  /// that predate an accepted seek from ones that follow it. Lives here
  /// because the stamp has to be taken on libVLC's thread, at emission.
  private let timelineRevision = Mutex<UInt64>(0)
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

  func broadcast(_ event: PlayerEvent, nativeHandleGeneration: UInt64) {
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
          event: event,
          timelineRevision: timelineRevision.withLock { $0 }
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

  func finishAll() {
    events.finishAll()
    sourcedEvents.finishAll()
  }

  /// Permanently closes both broadcasters, so streams handed out after this
  /// point are already finished rather than waiting on a source that will
  /// never emit again.
  func terminate() {
    events.terminate()
    sourcedEvents.terminate()
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
  if event.pointee.type == Int32(libvlc_MediaPlayerMediaStopping.rawValue) {
    coordinator.noteStoppingReason(event.pointee.u.media_player_media_stopping.reason)
  }
  let shouldSynthesizeEnd: Bool
  switch mapped {
  case .encounteredError:
    coordinator.markError()
    shouldSynthesizeEnd = false
  case .stateChanged(.stopped):
    shouldSynthesizeEnd = coordinator.consumeStoppedShouldSynthesizeEnd()
  default:
    shouldSynthesizeEnd = false
  }

  // Both emissions are made from the same immutable attachment token. Every
  // subscriber therefore observes `.stopped` then `.endReached` with one
  // generation, independent of consumer lag or native pointer reuse.
  context.broadcast(mapped, nativeHandleGeneration: attachment.nativeHandleGeneration)
  if shouldSynthesizeEnd {
    context.broadcast(
      .endReached,
      nativeHandleGeneration: attachment.nativeHandleGeneration
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
