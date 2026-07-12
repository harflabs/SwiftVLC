#if os(iOS) || os(macOS)

import CoreMedia

extension PiPController {
  struct PlaybackStateUpdate: Equatable {
    var invalidatesPlaybackState = false
    var requiresLinearPlayback: Bool?
  }

  /// Event-side snapshot for AVKit's playback UI on either PiP backend.
  ///
  /// `Player` and `PiPController` consume independent streams from the same
  /// native event. Their relative ordering is intentionally unspecified, so
  /// payload-bearing events must update this snapshot from their payload rather
  /// than from `Player`'s potentially stale observable mirror.
  struct PlaybackStateObservationState {
    private(set) var durationMilliseconds: Int64?
    private(set) var isSeekable: Bool

    init(duration: Duration?, isSeekable: Bool) {
      durationMilliseconds = duration?.milliseconds
      self.isSeekable = isSeekable
    }

    mutating func consume(
      _ event: PlayerEvent,
      observedDuration _: Duration?,
      observedIsSeekable _: Bool
    ) -> PlaybackStateUpdate {
      switch event {
      case .mediaChanged:
        // The new input's duration/seekability have not been reported yet.
        // Reset conservatively even if Player's event consumer still exposes
        // the previous media's values.
        durationMilliseconds = nil
        isSeekable = false
        return PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: true
        )

      case .lengthChanged(let duration):
        durationMilliseconds = duration.milliseconds
        return PlaybackStateUpdate(invalidatesPlaybackState: true)

      case .seekableChanged(let seekable):
        isSeekable = seekable
        return PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: !seekable
        )

      case .stateChanged:
        // State transitions are the only payload-free fallback that can
        // affect availability. Invalidate so AVKit re-queries the retained
        // native media snapshot instead of copying a potentially stale mirror.
        return PlaybackStateUpdate(invalidatesPlaybackState: true)

      default:
        return PlaybackStateUpdate()
      }
    }
  }

  static func applyPlaybackStateUpdate(
    _ update: PlaybackStateUpdate,
    setRequiresLinearPlayback: (Bool) -> Void,
    invalidatePlaybackState: () -> Void
  ) {
    if let requiresLinearPlayback = update.requiresLinearPlayback {
      setRequiresLinearPlayback(requiresLinearPlayback)
    }
    if update.invalidatesPlaybackState {
      invalidatePlaybackState()
    }
  }

  /// Converts AVKit's interval without using a trapping floating-point-to-
  /// integer conversion for invalid, infinite, or out-of-range `CMTime`s.
  static func skipOffsetMilliseconds(_ interval: CMTime) -> Int64? {
    guard interval.isNumeric else { return nil }
    let milliseconds = interval.seconds * 1000
    guard milliseconds.isFinite else { return nil }
    if milliseconds >= Double(Int64.max) {
      return .max
    }
    if milliseconds <= Double(Int64.min) {
      return .min
    }
    return Int64(milliseconds)
  }

  /// Saturating addition followed by clamping to the playable timeline.
  /// This keeps adversarial or malformed skip intervals from overflowing at
  /// either end while preserving the ordinary truncation-to-milliseconds
  /// behavior.
  static func clampedSkipTargetMilliseconds(
    current: Int64,
    offset: Int64,
    duration: Int64?
  ) -> Int64 {
    let upperBound = max(duration ?? .max, 0)
    let current = max(0, min(current, upperBound))
    let sum = current.addingReportingOverflow(offset)
    if sum.overflow {
      return offset >= 0 ? upperBound : 0
    }
    return max(0, min(sum.partialValue, upperBound))
  }
}

#endif
