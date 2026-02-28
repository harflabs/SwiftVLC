/// Events emitted by the ``Player`` event bridge.
///
/// Most consumers don't need to observe raw events — `@Observable` properties
/// on ``Player`` are updated automatically. Use ``Player/events`` only for
/// custom event processing.
public enum PlayerEvent: Sendable {
    case stateChanged(PlayerState)
    case timeChanged(Duration)
    case positionChanged(Double)
    case lengthChanged(Duration)
    case seekableChanged(Bool)
    case pausableChanged(Bool)
    case tracksChanged
    case mediaChanged
    case endReached
    case encounteredError
    case volumeChanged(Float)
    case muted
    case unmuted
    case voutChanged(Int)
    case bufferingProgress(Float) // 0.0...1.0
    case chapterChanged(Int)
    case recordingChanged(Bool, String?)
    case titleListChanged
    case titleSelectionChanged(Int)
    case snapshotTaken(String)
    case programAdded(Int)
    case programDeleted(Int)
    case programSelected(unselectedId: Int, selectedId: Int)
    case programUpdated(Int)
}
