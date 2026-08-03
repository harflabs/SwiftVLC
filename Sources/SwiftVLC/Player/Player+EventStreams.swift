/// Public and internal streams sourced from the player's native event bridge.
extension Player {
  /// Raw event stream for custom processing, with the default buffering
  /// policy (`.newest(64)`) and no filter.
  /// Most consumers should use `@Observable` properties instead.
  /// See ``events(policy:filter:)`` for the delivery guarantees and their
  /// limits.
  public nonisolated var events: AsyncStream<PlayerEvent> {
    eventBridge.makeStream(policy: .newest(64), filter: nil)
  }

  /// Raw event stream with an explicit buffering policy and an optional
  /// per-subscription filter.
  ///
  /// The default `.newest(64)` policy bounds memory but is lossy: a
  /// consumer stalled past 64 undelivered events silently loses the
  /// oldest ones, which can include one-shot terminal transitions such as
  /// `.stateChanged(.stopped)` or ``PlayerEvent/endReached-enum.case``. Consumers
  /// that must not miss those should pass `.unbounded`, ideally with a
  /// `filter` that keeps the `timeChanged`/`positionChanged` firehose out
  /// of the buffer.
  ///
  /// `filter` runs on libVLC's event thread for every event, outside any
  /// SwiftVLC lock — keep it fast and never block in it. Don't touch
  /// main-actor state from it: beyond the usual isolation rules, native
  /// teardown (handle replacement, player deinit) joins the event thread
  /// while detaching callbacks, so a filter blocked on the main actor
  /// can deadlock teardown against the very thread it is stalling.
  ///
  /// A delivery limit that no policy removes: when the player replaces
  /// its native handle (stopping drawable-hosted playback does this
  /// lazily, and ``recast(to:)``-style renderer changes do it
  /// mid-session), the bridge reattaches to the replacement handle before
  /// the old one finishes stopping on a background queue. Terminal events
  /// of the *swapped-out* handle are never delivered to any stream; state
  /// derived from them is reset by the swap itself.
  public nonisolated func events(
    policy: EventBufferingPolicy = .newest(64),
    filter: (@Sendable (PlayerEvent) -> Bool)? = nil
  ) -> AsyncStream<PlayerEvent> {
    eventBridge.makeStream(policy: policy, filter: filter)
  }

  /// Lossless stream of lifecycle state transitions — no firehose.
  ///
  /// Carries every change of ``state``, so a lagging consumer can never lose
  /// a one-shot terminal transition. Memory is bounded in practice by the low
  /// rate of state changes.
  ///
  /// Driven by the state itself rather than by the raw `.stateChanged` event,
  /// which is what makes it *complete*. libVLC reports a native failure as
  /// `.encounteredError` and buffering as `.bufferingProgress`, so neither
  /// ever produced a `.stateChanged` to forward: a stream built by filtering
  /// raw events silently omitted every transition to ``PlayerState/error``
  /// and ``PlayerState/buffering``. Anything waiting on `.error` here waited
  /// for something that could not arrive.
  ///
  /// Buffering is published at most once per entry into it — repeated
  /// progress reports do not re-announce the state — so completeness does not
  /// cost the no-firehose guarantee.
  ///
  /// Not de-duplicated: the same state published twice is delivered twice.
  /// Same-player media replacement currently restarts a session on a repeated
  /// `.playing`, so suppressing repeats would break it until events carry a
  /// media generation to distinguish sessions by. Treat a value as "the
  /// current state", not as "a value that differs from the last one".
  public nonisolated var stateTransitions: AsyncStream<PlayerState> {
    // Explicitly unbounded. `subscribe()` defaults to newest-64, which would
    // make a stream documented as lossless silently drop the oldest pending
    // transitions under a stalled consumer — losing exactly the one-shot
    // terminal states this exists to protect.
    stateTransitionBridge.subscribe(policy: .unbounded)
  }

  nonisolated var playbackIntentEvents: AsyncStream<Bool> {
    playbackIntentBridge.subscribe()
  }
}
