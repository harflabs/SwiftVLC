import CLibVLC
import Foundation
import Synchronization

/// Bridges libVLC C event callbacks to `AsyncStream<PlayerEvent>`.
///
/// Multi-consumer broadcaster: each call to `makeStream()` returns an
/// independent `AsyncStream`. The C callback yields to ALL registered
/// continuations via a `Mutex`-protected store.
final class EventBridge: Sendable {
  private nonisolated(unsafe) let eventManager: OpaquePointer
  private let store: ContinuationStore
  private nonisolated(unsafe) let storeOpaque: UnsafeMutableRawPointer
  private let invalidated = Mutex(false)

  init(eventManager: OpaquePointer) {
    self.eventManager = eventManager

    let store = ContinuationStore()
    self.store = store
    let opaque = Unmanaged.passRetained(store).toOpaque()
    storeOpaque = opaque

    for eventType in Self.playerEventTypes {
      libvlc_event_attach(eventManager, eventType, playerEventCallback, opaque)
    }
  }

  deinit {
    invalidate()
    Unmanaged<ContinuationStore>.fromOpaque(storeOpaque).release()
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

    for eventType in Self.playerEventTypes {
      libvlc_event_detach(eventManager, eventType, playerEventCallback, storeOpaque)
    }
    store.finishAll()
  }

  /// Creates a new independent `AsyncStream` for consuming player events.
  /// Each stream receives all events broadcast after creation.
  func makeStream() -> AsyncStream<PlayerEvent> {
    let id = UUID()
    let store = store
    let (stream, continuation) = AsyncStream<PlayerEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
    store.add(id: id, continuation: continuation)
    continuation.onTermination = { _ in
      store.remove(id: id)
    }
    return stream
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
    libvlc_MediaPlayerMuted,
    libvlc_MediaPlayerUnmuted,
    libvlc_MediaPlayerAudioVolume,
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
}

// MARK: - Continuation Store

/// Thread-safe storage for multiple `AsyncStream` continuations.
/// Passed to C callbacks via `Unmanaged`.
private final class ContinuationStore: Sendable {
  private let continuations: Mutex<[UUID: AsyncStream<PlayerEvent>.Continuation]> = Mutex([:])

  func add(id: UUID, continuation: AsyncStream<PlayerEvent>.Continuation) {
    continuations.withLock { $0[id] = continuation }
  }

  func remove(id: UUID) {
    continuations.withLock { _ = $0.removeValue(forKey: id) }
  }

  func broadcast(_ event: PlayerEvent) {
    continuations.withLock { dict in
      for cont in dict.values {
        cont.yield(event)
      }
    }
  }

  func finishAll() {
    continuations.withLock { dict in
      for cont in dict.values {
        cont.finish()
      }
      dict.removeAll()
    }
  }
}

// MARK: - C Callback (free function)

/// Free function — runs on libVLC's internal event thread.
/// `AsyncStream.Continuation.yield` is documented safe from any thread.
private func playerEventCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let store = Unmanaged<ContinuationStore>.fromOpaque(opaque).takeUnretainedValue()

  if let mapped = mapEvent(event.pointee) {
    store.broadcast(mapped)
  }
}

private func mapEvent(_ event: libvlc_event_t) -> PlayerEvent? {
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

  case libvlc_MediaPlayerAudioVolume:
    let vol = event.u.media_player_audio_volume.volume
    return .volumeChanged(vol)

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
