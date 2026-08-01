/// Which delivery lane an event belongs to.
///
/// libVLC mixes two very different kinds of event on one callback: one-shot
/// facts that a consumer must never miss, and a continuous telemetry firehose
/// where only the latest value matters. Delivering both through a single
/// bounded buffer means a burst of the second can silently evict the first —
/// `timeChanged` alone fires around 30 Hz during playback, so a consumer
/// stalled for two seconds can lose a `.mediaChanged` or an `.endReached` that
/// happened to be queued behind it.
///
/// Splitting them into separate buffers removes that coupling structurally: a
/// timing burst cannot evict a control event because timing events never enter
/// the control buffer at all.
public enum PlayerEventLane: Sendable, Equatable, CaseIterable {
  /// One-shot events: media identity, capability, lifecycle, and terminal
  /// outcomes. Losing one leaves a consumer permanently wrong, so this lane is
  /// delivered losslessly.
  case control

  /// Continuous events: the playback clock, buffer fill, and render counters.
  /// Each supersedes the one before it, so dropping a backlog costs nothing
  /// beyond resolution and the newest value still arrives.
  case timing
}

extension PlayerEvent {
  /// The lane this event is delivered on. See ``PlayerEventLane``.
  public var lane: PlayerEventLane {
    switch self {
    case .timeChanged,
         .positionChanged,
         .bufferingProgress,
         .voutChanged:
      // Superseded by the next sample of the same kind. `voutChanged` is a
      // counter rather than a transition: the newest count is the truth, and
      // an intermediate one carries no information the newest lacks.
      .timing

    case .stateChanged,
         .mediaChanged,
         .mediaStopping,
         .endReached,
         .encounteredError,
         .lengthChanged,
         .seekableChanged,
         .pausableChanged,
         .tracksChanged,
         .volumeChanged,
         .muted,
         .unmuted,
         .corked,
         .uncorked,
         .audioDeviceChanged,
         .chapterChanged,
         .recordingChanged,
         .titleListChanged,
         .titleSelectionChanged,
         .snapshotTaken,
         .programAdded,
         .programDeleted,
         .programSelected,
         .programUpdated:
      // Each reports something that happened once. There is no later event
      // that re-states it, so a dropped one is lost information.
      .control
    }
  }
}

extension Player {
  /// Lossless stream of one-shot control events — media identity, capability,
  /// lifecycle, and terminal outcomes.
  ///
  /// Prefer this over ``events`` whenever missing an event would leave your
  /// state wrong. The default ``events`` stream mixes both lanes into one
  /// bounded buffer, so a consumer stalled past 64 undelivered events can lose
  /// a `.mediaChanged` or an ``PlayerEvent/endReached-enum.case`` that happened
  /// to be queued behind a burst of clock samples. Here the firehose is
  /// excluded from the buffer entirely, so no volume of timing events can hide
  /// a control event no matter how long the consumer stalls.
  ///
  /// Delivery is unbounded, which is safe precisely because control events are
  /// rare: memory grows with consumer lag times the *control* event rate, not
  /// the clock rate. Pair with ``timingEvents`` when you also need the clock.
  ///
  /// The handle-replacement limit described on ``events(policy:filter:)``
  /// applies here too.
  public nonisolated var controlEvents: AsyncStream<PlayerEvent> {
    eventBridge.makeStream(policy: .unbounded, filter: { $0.lane == .control })
  }

  /// Lossless control events paired with their native-handle and playback
  /// generations.
  ///
  /// No timing volume can evict a value because timing events never enter
  /// this stream. Compare each envelope with ``nativeEventGeneration`` and
  /// ``generation`` before applying work that may outlive a handle replacement
  /// or media change.
  public nonisolated var controlEventEnvelopes: AsyncStream<PlayerEventEnvelope> {
    eventBridge.makeEnvelopeStream(policy: .unbounded) { envelope in
      envelope.event.lane == .control
    }
  }

  /// Coalesced stream of continuous events — the playback clock, buffer fill,
  /// and render counters.
  ///
  /// Bounded and lossy by design: each event supersedes the one before it, so
  /// a lagging consumer skips stale samples and still receives the newest.
  /// Because control events are not in this buffer, dropping from it can never
  /// cost a one-shot transition.
  ///
  /// The buffer keeps the newest ``Player/timingLaneBufferSize`` events across
  /// the lane as a whole — it is **not** one slot per event kind. A consumer
  /// stalled across a long enough burst of the fastest kind (`timeChanged`, at
  /// roughly 30 Hz) can therefore still lose the newest sample of a slower one
  /// such as `voutChanged`.
  ///
  /// That is a real limit, not a claim to have solved it. Per-kind coalescing
  /// would need a keyed buffer rather than `AsyncStream`'s newest-N policy.
  /// What the lane split does guarantee is the part that matters for
  /// correctness: nothing dropped here can ever be a one-shot control event,
  /// because control events are not in this buffer. If you need a timing value
  /// you cannot afford to miss, read it from `Player`'s observable properties,
  /// which are fed by the lossless internal stream.
  public nonisolated var timingEvents: AsyncStream<PlayerEvent> {
    eventBridge.makeStream(
      policy: .newest(Self.timingLaneBufferSize),
      filter: { $0.lane == .timing }
    )
  }

  /// Coalesced timing events paired with their native-handle and playback
  /// generations.
  public nonisolated var timingEventEnvelopes: AsyncStream<PlayerEventEnvelope> {
    eventBridge.makeEnvelopeStream(policy: .newest(Self.timingLaneBufferSize)) { envelope in
      envelope.event.lane == .timing
    }
  }

  /// Newest-N across the whole timing lane. Sized to hold at least one of each
  /// timing kind so a *short* backlog does not starve the slower ones; a long
  /// enough burst of one kind will still evict the others.
  nonisolated static let timingLaneBufferSize = 4
}
