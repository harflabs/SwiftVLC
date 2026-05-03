import CLibVLC
import os
import Synchronization

/// Bridges libVLC C event callbacks to `AsyncStream<PlayerEvent>`.
///
/// Multi-consumer fan-out built on `Broadcaster<PlayerEvent>`. Each call
/// to `makeStream()` returns an independent `AsyncStream`. The C callback
/// reaches the broadcaster through an `Unmanaged.passRetained` pointer
/// passed to libVLC's `event_attach`, then calls `broadcast(_:)` which
/// snapshots subscribers under a Mutex and yields outside the lock.
final class EventBridge: Sendable {
  private nonisolated(unsafe) var eventManager: OpaquePointer
  private let broadcaster: Broadcaster<PlayerEvent>
  private nonisolated(unsafe) let broadcasterOpaque: UnsafeMutableRawPointer
  private nonisolated(unsafe) var attachedEventTypes: [Int32]
  private let invalidated = Mutex(false)

  init(eventManager: OpaquePointer) {
    self.eventManager = eventManager

    let broadcaster = Broadcaster<PlayerEvent>(defaultBufferSize: 64)
    self.broadcaster = broadcaster
    let opaque = Unmanaged.passRetained(broadcaster).toOpaque()
    broadcasterOpaque = opaque

    attachedEventTypes = Self.attachEvents(to: eventManager, opaque: opaque)
  }

  deinit {
    invalidate()
    Unmanaged<Broadcaster<PlayerEvent>>.fromOpaque(broadcasterOpaque).release()
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

    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: broadcasterOpaque)
    attachedEventTypes = []
    broadcaster.finishAll()
  }

  /// Moves the existing streams to a replacement native media player.
  ///
  /// `Player` recreates its libVLC handle after a stopped drawable-backed
  /// playback because libVLC keeps a "free vout" whose iOS window provider
  /// still points at the old UIView. The Swift `Player.events` stream must
  /// survive that native-handle swap, so this detaches callbacks from the old
  /// event manager and attaches the same broadcaster to the new one.
  func reattach(to newEventManager: OpaquePointer) {
    let isInvalidated = invalidated.withLock { $0 }
    guard !isInvalidated else { return }

    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: broadcasterOpaque)
    eventManager = newEventManager
    attachedEventTypes = Self.attachEvents(to: newEventManager, opaque: broadcasterOpaque)
  }

  /// Creates a new independent `AsyncStream` for consuming player events.
  /// Each stream receives all events broadcast after creation.
  func makeStream() -> AsyncStream<PlayerEvent> {
    broadcaster.subscribe()
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

  let broadcaster = Unmanaged<Broadcaster<PlayerEvent>>.fromOpaque(opaque).takeUnretainedValue()

  if let mapped = mapEvent(event.pointee) {
    broadcaster.broadcast(mapped)
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
