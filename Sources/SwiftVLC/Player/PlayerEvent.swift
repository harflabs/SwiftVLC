/// Raw events from the libVLC event bridge.
///
/// Most consumers should use ``Player``'s `@Observable` properties instead.
/// Use ``Player/events`` only when you need event-level granularity.
public enum PlayerEvent: Sendable {
  /// Playback state changed.
  case stateChanged(PlayerState)
  /// Current playback time updated.
  case timeChanged(Duration)
  /// Fractional position updated (0.0–1.0).
  case positionChanged(Double)
  /// Media duration became known or changed.
  case lengthChanged(Duration)
  /// Seekability changed.
  case seekableChanged(Bool)
  /// Pausability changed.
  case pausableChanged(Bool)
  /// Track list was modified (added, removed, or updated).
  case tracksChanged
  /// A different media was set on the player.
  case mediaChanged
  /// The player encountered an unrecoverable error.
  case encounteredError
  /// Audio volume changed. The value is normalized (0.0 = silent, 1.0 = 100%).
  case volumeChanged(Float)
  /// Audio was muted.
  case muted
  /// Audio was unmuted.
  case unmuted
  /// Number of active video outputs changed.
  case voutChanged(Int)
  /// Buffer fill level during initial load (0.0–1.0).
  case bufferingProgress(Float)
  /// Current chapter changed.
  case chapterChanged(Int)
  /// Recording state changed, with the output file path when stopped.
  case recordingChanged(isRecording: Bool, filePath: String?)
  /// The list of available titles changed.
  case titleListChanged
  /// A different title was selected.
  case titleSelectionChanged(Int)
  /// A video snapshot was saved to disk at the given file path.
  case snapshotTaken(String)
  /// A DVB/MPEG-TS program was added (value is the program group ID).
  case programAdded(Int)
  /// A DVB/MPEG-TS program was removed (value is the program group ID).
  case programDeleted(Int)
  /// The selected program changed.
  case programSelected(unselectedId: Int, selectedId: Int)
  /// A DVB/MPEG-TS program's metadata was updated (value is the program group ID).
  case programUpdated(Int)
}
