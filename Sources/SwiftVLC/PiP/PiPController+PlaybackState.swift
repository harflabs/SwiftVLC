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
    /// The capability generation current when this media was adopted.
    private var generationAtReset: UInt64?
    /// Whether `Player`'s capability values are known to describe *this*
    /// media. False between seeing a media change and seeing evidence that
    /// `Player` has processed the same change.
    private var trustsPolledCapability = true
    /// Set once a payload has reported the value for this media. A payload is
    /// authoritative for its generation; the polled mirror may only fill in
    /// what no payload has covered, never contradict one.
    private var hasDurationPayload = false
    private var hasSeekablePayload = false

    init(duration: Duration?, isSeekable: Bool) {
      durationMilliseconds = duration?.milliseconds
      self.isSeekable = isSeekable
    }

    mutating func consume(
      _ event: PlayerEvent,
      capability: PlayerCapabilitySnapshot
    ) -> PlaybackStateUpdate {
      switch event {
      case .mediaChanged:
        // The new input's duration/seekability have not been reported yet.
        // Reset conservatively even if Player's event consumer still exposes
        // the previous media's values.
        durationMilliseconds = nil
        isSeekable = false
        hasDurationPayload = false
        hasSeekablePayload = false
        generationAtReset = capability.generation
        // If the snapshot already holds the reset values, `Player` has
        // processed this same media change and its capability can be trusted
        // straight away — the common case, since `load(_:)` resets
        // synchronously. Otherwise the snapshot still describes the outgoing
        // media and must be ignored until the generation moves on.
        trustsPolledCapability = capability.isReset
        return PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: true
        )

      case .lengthChanged(let duration):
        hasDurationPayload = true
        durationMilliseconds = duration.milliseconds
        return PlaybackStateUpdate(invalidatesPlaybackState: true)

      case .seekableChanged(let seekable):
        hasSeekablePayload = true
        isSeekable = seekable
        return PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: !seekable
        )

      case .stateChanged:
        // State transitions are the only payload-free fallback that can
        // affect availability. Invalidate so AVKit re-queries the retained
        // native media snapshot instead of copying a potentially stale mirror.
        //
        // They are also where convergence happens: `Player` polls duration and
        // seekability on every transition precisely because libVLC does not
        // reliably emit the change events. Reacting only to those events left
        // finite seekable VOD pinned to the conservative media-changed reset —
        // linear playback with no skip controls.
        return reconcile(with: capability, invalidates: true)

      case .timeChanged:
        // `Player` polls from its own `.timeChanged` handler too, and does so
        // exactly while duration or seekability are still unknown. Steady
        // playback can run without another state transition, so convergence
        // has to be reachable from a clock tick as well.
        //
        // `invalidates: false` because this fires at the clock rate: it must
        // publish only when a value genuinely changed.
        return reconcile(with: capability, invalidates: false)

      default:
        return PlaybackStateUpdate()
      }
    }

    /// Folds `Player`'s polled capability into this snapshot, when it can be
    /// shown to describe the same media.
    private mutating func reconcile(
      with capability: PlayerCapabilitySnapshot,
      invalidates: Bool
    )
      -> PlaybackStateUpdate {
      var update = PlaybackStateUpdate(invalidatesPlaybackState: invalidates)

      if !trustsPolledCapability {
        // The generation moving past the one seen at the reset is the proof
        // that `Player` has processed the media change; its capability now
        // describes this media rather than the outgoing one.
        guard capability.generation != generationAtReset else { return update }
        trustsPolledCapability = true
      }

      if
        !hasDurationPayload,
        let milliseconds = capability.durationMilliseconds,
        milliseconds != durationMilliseconds {
        durationMilliseconds = milliseconds
        update.invalidatesPlaybackState = true
      }

      if !hasSeekablePayload, capability.isSeekable != isSeekable {
        isSeekable = capability.isSeekable
        update.requiresLinearPlayback = !capability.isSeekable
        update.invalidatesPlaybackState = true
      }

      return update
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
