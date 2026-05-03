/// Raw events from the libVLC event bridge.
///
/// Most consumers should use ``Player``'s `@Observable` properties instead.
/// Use ``Player/events`` only when you need event-level granularity.
public enum PlayerEvent: Sendable, CustomStringConvertible {
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
  /// Audio playback was suspended by the system (e.g. phone call, headphones
  /// unplugged with mix-with-others disabled). The player is paused until
  /// ``uncorked-enum.case`` fires.
  case corked
  /// Audio playback resumed after a cork (e.g. call ended).
  case uncorked
  /// The active audio output device changed. Value is the new device
  /// identifier, or `nil` if unknown.
  case audioDeviceChanged(String?)
  /// The current media is stopping. A good time to release input resources
  /// (network connections, custom I/O callbacks). The player emits this
  /// before transitioning to ``PlayerState/stopped``.
  case mediaStopping
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

  public var description: String {
    switch self {
    case .stateChanged(let state): "stateChanged(\(state))"
    case .timeChanged(let time): "timeChanged(\(time.formatted))"
    case .positionChanged(let position): "positionChanged(\(position))"
    case .lengthChanged(let length): "lengthChanged(\(length.formatted))"
    case .seekableChanged(let seekable): "seekableChanged(\(seekable))"
    case .pausableChanged(let pausable): "pausableChanged(\(pausable))"
    case .tracksChanged: "tracksChanged"
    case .mediaChanged: "mediaChanged"
    case .encounteredError: "encounteredError"
    case .volumeChanged(let volume): "volumeChanged(\(volume))"
    case .muted: "muted"
    case .unmuted: "unmuted"
    case .corked: "corked"
    case .uncorked: "uncorked"
    case .audioDeviceChanged(let device): "audioDeviceChanged(\(device ?? "nil"))"
    case .mediaStopping: "mediaStopping"
    case .voutChanged(let count): "voutChanged(\(count))"
    case .bufferingProgress(let progress): "bufferingProgress(\(progress))"
    case .chapterChanged(let chapter): "chapterChanged(\(chapter))"
    case .recordingChanged(let isRecording, let filePath):
      "recordingChanged(isRecording: \(isRecording), filePath: \(filePath ?? "nil"))"
    case .titleListChanged: "titleListChanged"
    case .titleSelectionChanged(let title): "titleSelectionChanged(\(title))"
    case .snapshotTaken(let path): "snapshotTaken(\(path))"
    case .programAdded(let id): "programAdded(\(id))"
    case .programDeleted(let id): "programDeleted(\(id))"
    case .programSelected(let unselected, let selected):
      "programSelected(unselectedId: \(unselected), selectedId: \(selected))"
    case .programUpdated(let id): "programUpdated(\(id))"
    }
  }
}

// MARK: - Per-case accessors

extension PlayerEvent {
  /// `PlayerState` if this event is `.stateChanged`, otherwise `nil`.
  public var stateChanged: PlayerState? {
    if case .stateChanged(let value) = self { value } else { nil }
  }

  /// `Duration` if this event is `.timeChanged`, otherwise `nil`.
  public var timeChanged: Duration? {
    if case .timeChanged(let value) = self { value } else { nil }
  }

  /// `Double` if this event is `.positionChanged`, otherwise `nil`.
  public var positionChanged: Double? {
    if case .positionChanged(let value) = self { value } else { nil }
  }

  /// `Duration` if this event is `.lengthChanged`, otherwise `nil`.
  public var lengthChanged: Duration? {
    if case .lengthChanged(let value) = self { value } else { nil }
  }

  /// `Bool` if this event is `.seekableChanged`, otherwise `nil`.
  public var seekableChanged: Bool? {
    if case .seekableChanged(let value) = self { value } else { nil }
  }

  /// `Bool` if this event is `.pausableChanged`, otherwise `nil`.
  public var pausableChanged: Bool? {
    if case .pausableChanged(let value) = self { value } else { nil }
  }

  /// `Void` if this event is `.tracksChanged`, otherwise `nil`.
  public var tracksChanged: Void? {
    if case .tracksChanged = self { () } else { nil }
  }

  /// `Void` if this event is `.mediaChanged`, otherwise `nil`.
  public var mediaChanged: Void? {
    if case .mediaChanged = self { () } else { nil }
  }

  /// `Void` if this event is `.encounteredError`, otherwise `nil`.
  public var encounteredError: Void? {
    if case .encounteredError = self { () } else { nil }
  }

  /// `Float` if this event is `.volumeChanged`, otherwise `nil`.
  public var volumeChanged: Float? {
    if case .volumeChanged(let value) = self { value } else { nil }
  }

  /// `Void` if this event is `.muted`, otherwise `nil`.
  public var muted: Void? {
    if case .muted = self { () } else { nil }
  }

  /// `Void` if this event is `.unmuted`, otherwise `nil`.
  public var unmuted: Void? {
    if case .unmuted = self { () } else { nil }
  }

  /// `Void` if this event is `.corked`, otherwise `nil`.
  public var corked: Void? {
    if case .corked = self { () } else { nil }
  }

  /// `Void` if this event is `.uncorked`, otherwise `nil`.
  public var uncorked: Void? {
    if case .uncorked = self { () } else { nil }
  }

  /// Optional `String?` if this event is `.audioDeviceChanged`,
  /// otherwise `nil`. Distinguishing the wrapping nil (the event
  /// didn't fire) from the inner nil (the device was unspecified)
  /// requires `if case .audioDeviceChanged(let device) = event`.
  public var audioDeviceChanged: String?? {
    if case .audioDeviceChanged(let value) = self { value } else { nil }
  }

  /// `Void` if this event is `.mediaStopping`, otherwise `nil`.
  public var mediaStopping: Void? {
    if case .mediaStopping = self { () } else { nil }
  }

  /// `Int` if this event is `.voutChanged`, otherwise `nil`.
  public var voutChanged: Int? {
    if case .voutChanged(let value) = self { value } else { nil }
  }

  /// `Float` if this event is `.bufferingProgress`, otherwise `nil`.
  public var bufferingProgress: Float? {
    if case .bufferingProgress(let value) = self { value } else { nil }
  }

  /// `Int` if this event is `.chapterChanged`, otherwise `nil`.
  public var chapterChanged: Int? {
    if case .chapterChanged(let value) = self { value } else { nil }
  }

  /// Tuple of `(isRecording: Bool, filePath: String?)` if this event is
  /// `.recordingChanged`, otherwise `nil`.
  public var recordingChanged: (isRecording: Bool, filePath: String?)? {
    if case .recordingChanged(let isRecording, let filePath) = self {
      (isRecording: isRecording, filePath: filePath)
    } else {
      nil
    }
  }

  /// `Void` if this event is `.titleListChanged`, otherwise `nil`.
  public var titleListChanged: Void? {
    if case .titleListChanged = self { () } else { nil }
  }

  /// `Int` if this event is `.titleSelectionChanged`, otherwise `nil`.
  public var titleSelectionChanged: Int? {
    if case .titleSelectionChanged(let value) = self { value } else { nil }
  }

  /// `String` (path) if this event is `.snapshotTaken`, otherwise `nil`.
  public var snapshotTaken: String? {
    if case .snapshotTaken(let value) = self { value } else { nil }
  }

  /// Program group ID if this event is `.programAdded`, otherwise `nil`.
  public var programAdded: Int? {
    if case .programAdded(let value) = self { value } else { nil }
  }

  /// Program group ID if this event is `.programDeleted`, otherwise `nil`.
  public var programDeleted: Int? {
    if case .programDeleted(let value) = self { value } else { nil }
  }

  /// Tuple of `(unselectedId: Int, selectedId: Int)` if this event is
  /// `.programSelected`, otherwise `nil`.
  public var programSelected: (unselectedId: Int, selectedId: Int)? {
    if case .programSelected(let unselected, let selected) = self {
      (unselectedId: unselected, selectedId: selected)
    } else {
      nil
    }
  }

  /// Program group ID if this event is `.programUpdated`, otherwise `nil`.
  public var programUpdated: Int? {
    if case .programUpdated(let value) = self { value } else { nil }
  }
}
