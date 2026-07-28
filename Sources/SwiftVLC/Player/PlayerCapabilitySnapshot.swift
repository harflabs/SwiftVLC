import Synchronization

/// Duration and seekability tagged with the media generation they describe.
///
/// ``Player`` repairs both by polling, because libVLC does not reliably emit
/// `MediaPlayerSeekableChanged` or `MediaPlayerLengthChanged`. Consumers that
/// react only to those raw events therefore miss capability the poll
/// discovered — but they cannot simply read `Player`'s observable mirror
/// either, because `Player` and its consumers process the same native event on
/// independent schedules, so the mirror can still describe the *previous*
/// media.
///
/// The generation resolves that: a reader can tell whether the values in front
/// of it belong to the media it currently believes is loaded, instead of
/// guessing from arrival order.
struct PlayerCapabilitySnapshot: Sendable, Equatable {
  /// Bumped whenever the loaded media changes.
  var generation: UInt64 = 0
  var durationMilliseconds: Int64?
  var isSeekable = false

  /// Whether these are the conservative values a media starts at.
  ///
  /// Seeing this immediately after a media change is how a reader knows
  /// `Player` has already processed that change, rather than still holding the
  /// outgoing media's capability.
  var isReset: Bool {
    durationMilliseconds == nil && !isSeekable
  }
}

extension Player {
  /// Republishes ``duration`` and ``isSeekable`` under the current generation.
  ///
  /// A no-op while a multi-property change is in flight: publishing after each
  /// individual assignment would let a reader observe one media's duration
  /// beside another's seekability.
  func publishCapabilitySnapshot() {
    guard !isSuppressingCapabilityPublish else { return }
    let milliseconds = duration?.milliseconds
    let seekable = isSeekable
    capabilitySnapshot.withLock { snapshot in
      snapshot.durationMilliseconds = milliseconds
      snapshot.isSeekable = seekable
    }
  }

  /// Starts a new capability generation with the conservative values.
  ///
  /// Called from ``resetMediaDerivedState()``, so the bump and the reset are
  /// atomic from a reader's point of view: there is no window in which the new
  /// generation is visible alongside the previous media's values.
  func advanceCapabilityGeneration() {
    capabilitySnapshot.withLock { snapshot in
      snapshot.generation &+= 1
      snapshot.durationMilliseconds = nil
      snapshot.isSeekable = false
    }
  }
}
