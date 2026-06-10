import Dispatch
import os
import Synchronization

/// A multi-consumer broadcaster of `Sendable` values.
///
/// Each call to ``subscribe(policy:filter:)`` returns an
/// independent `AsyncStream`. Producers call ``broadcast(_:)`` to send
/// a value to every active subscriber whose `filter` accepts it.
///
/// ## Lock discipline (AB-BA prevention)
///
/// `broadcast` snapshots the matching continuations under the lock and
/// yields *outside* it. If the lock were held during yield, a concurrent
/// task cancellation (which holds the cancelling task's status-record
/// lock and calls `onTermination → unsubscribe → acquire Mutex`) could
/// produce an AB-BA deadlock with `broadcast → acquire Mutex → yield →
/// acquire status-record lock`. Yielding outside the lock breaks the
/// cycle.
///
/// ## Lifecycle callbacks
///
/// `onFirstSubscriber` and `onLastUnsubscribed` let lazy producers
/// (like the libVLC log callback installer) attach to and detach from
/// their upstream source only when there's actual demand. Both callbacks
/// run on a serial reconciliation queue so they can safely make C calls
/// without racing each other.
final class Broadcaster<Element: Sendable>: Sendable {
  /// Per-subscriber predicate. Returning `false` skips this subscriber
  /// for the broadcast, *without* removing them from the broadcaster.
  typealias Filter = @Sendable (Element) -> Bool

  private struct Subscriber {
    let continuation: AsyncStream<Element>.Continuation
    let filter: Filter?
  }

  private struct State {
    var nextID: Int = 0
    var subscribers: [Int: Subscriber] = [:]
    /// Whether the upstream source is currently attached (lifecycle
    /// callbacks installed). Written only between callbacks on the
    /// reconciliation queue, so attach/detach strictly alternate.
    var attached = false
    /// Once `true`, the broadcaster is permanently terminated. New
    /// `subscribe(...)` calls return immediately-finished streams and
    /// `broadcast(_:)` is a no-op. Set by ``terminate()``.
    var terminated: Bool = false
  }

  private let state = Mutex(State())
  private let defaultBufferSize: Int
  private let onFirstSubscriber: @Sendable () -> Void
  private let onLastUnsubscribed: @Sendable () -> Void
  private let reconciliation: ReconciliationQueue

  /// Creates a broadcaster.
  ///
  /// - Parameters:
  ///   - defaultBufferSize: Default buffer size used for streams created
  ///     by `subscribe` when the caller doesn't override it. The buffer
  ///     uses `.bufferingNewest`, so slow consumers drop oldest events
  ///     rather than block the producer.
  ///   - onFirstSubscriber: Fires when subscriber count goes 0 → 1.
  ///     Use to attach to the upstream source (install a libVLC callback,
  ///     start polling, etc.). Runs on a private serial queue so concurrent
  ///     subscribe/unsubscribe storms can't double-fire it.
  ///   - onLastUnsubscribed: Fires when subscriber count goes N → 0.
  ///     Symmetric counterpart to `onFirstSubscriber`. Same execution
  ///     guarantee.
  init(
    defaultBufferSize: Int = 64,
    onFirstSubscriber: @escaping @Sendable () -> Void = {},
    onLastUnsubscribed: @escaping @Sendable () -> Void = {}
  ) {
    self.defaultBufferSize = defaultBufferSize
    self.onFirstSubscriber = onFirstSubscriber
    self.onLastUnsubscribed = onLastUnsubscribed
    reconciliation = ReconciliationQueue()
  }

  /// Returns an independent `AsyncStream` that yields every element
  /// passed to ``broadcast(_:)`` while the stream is alive.
  ///
  /// - Parameters:
  ///   - policy: Buffering behavior for this stream. `nil` uses the
  ///     broadcaster's default size with the newest-wins policy.
  ///   - filter: Optional per-subscriber predicate. Only elements for
  ///     which `filter` returns `true` are yielded to this stream.
  func subscribe(
    policy: EventBufferingPolicy? = nil,
    filter: Filter? = nil
  ) -> AsyncStream<Element> {
    // `bufferingNewest(0)` (or a negative count) silently drops every
    // element yielded while no consumer is suspended in `next()` —
    // clamping to 1 keeps a degenerate count from producing a stream
    // that loses essentially everything with no signal.
    let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy =
      switch policy ?? .newest(defaultBufferSize) {
      case .newest(let count): .bufferingNewest(Swift.max(1, count))
      case .unbounded: .unbounded
      }
    let (stream, continuation) = AsyncStream<Element>.makeStream(
      bufferingPolicy: bufferingPolicy
    )

    // The reconciliation pass is scheduled while the lock is still held
    // (`DispatchQueue.async` never blocks): if it were scheduled after
    // unlocking, a concurrent membership change could enqueue its own
    // pass first, and the FIFO queue would observe the transitions in
    // the wrong order.
    let id = state.withLock { state -> Int? in
      guard !state.terminated else { return nil }
      let id = state.nextID
      state.nextID += 1
      state.subscribers[id] = Subscriber(continuation: continuation, filter: filter)
      if state.subscribers.count == 1 {
        scheduleReconciliation()
      }
      return id
    }

    guard let id else {
      continuation.finish()
      return stream
    }

    continuation.onTermination = { [weak self] _ in
      self?.unsubscribe(id: id)
    }

    return stream
  }

  /// Sends an element to every subscriber whose filter accepts it.
  ///
  /// Safe to call from any thread, including from a libVLC C callback.
  /// Subscriber filters and yields run outside the broadcaster's lock —
  /// load-bearing twice over: a slow consumer can't block other consumers
  /// or the producer, and a user-supplied filter that touches this
  /// broadcaster again (subscribe, `isEmpty`, even `broadcast`) cannot
  /// deadlock on the non-recursive `Mutex` or stall libVLC's event
  /// thread while it holds the lock.
  func broadcast(_ element: Element) {
    let interval = Signposts.signposter.beginInterval("Broadcaster.broadcast")
    let snapshot = state.withLock { state -> Snapshot in
      guard !state.terminated, !state.subscribers.isEmpty else { return .none }
      if state.subscribers.count == 1, let only = state.subscribers.values.first {
        return .single(only)
      }
      return .many(Array(state.subscribers.values))
    }
    var delivered = 0
    switch snapshot {
    case .none:
      break
    case .single(let sub):
      if sub.filter?(element) ?? true {
        sub.continuation.yield(element)
        delivered = 1
      }
    case .many(let subs):
      for sub in subs where sub.filter?(element) ?? true {
        sub.continuation.yield(element)
        delivered += 1
      }
    }
    Signposts.signposter.endInterval("Broadcaster.broadcast", interval, "subs=\(delivered)")
  }

  private enum Snapshot {
    case none
    case single(Subscriber)
    case many([Subscriber])
  }

  /// Returns `true` if at least one subscriber's filter would accept the
  /// given probe element. Use to skip expensive payload construction
  /// when no consumer is interested.
  func hasSubscriber(matching probe: Element) -> Bool {
    state.withLock { state in
      state.subscribers.values.contains { sub in
        sub.filter?(probe) ?? true
      }
    }
  }

  /// Returns `true` when there are no active subscribers, regardless of
  /// any filters.
  var isEmpty: Bool {
    state.withLock { $0.subscribers.isEmpty }
  }

  /// Finishes every active stream and removes its continuation.
  ///
  /// Subsequent calls to `broadcast(_:)` are no-ops until new
  /// subscribers attach. New subscribers re-attach normally.
  /// `onLastUnsubscribed` fires on the reconciliation queue.
  ///
  /// Use ``terminate()`` instead when the broadcaster's underlying
  /// source is permanently gone — that variant also closes future
  /// `subscribe(...)` calls so they return immediately-finished
  /// streams.
  func finishAll() {
    let snapshot = state.withLock { state -> [Subscriber] in
      let subs = Array(state.subscribers.values)
      state.subscribers.removeAll()
      if !subs.isEmpty {
        scheduleReconciliation()
      }
      return subs
    }
    for sub in snapshot {
      sub.continuation.finish()
    }
  }

  /// Permanently terminates the broadcaster.
  ///
  /// Finishes every active stream, makes future calls to
  /// ``subscribe(policy:filter:)`` return immediately-finished
  /// streams, and makes ``broadcast(_:)`` a no-op. `onLastUnsubscribed`
  /// fires on the reconciliation queue if there were active subscribers.
  ///
  /// Use when the broadcaster's underlying source is gone for good
  /// (handler deinit, registration loss). If subscribers may re-attach,
  /// use ``finishAll()`` instead.
  func terminate() {
    let snapshot = state.withLock { state -> [Subscriber] in
      state.terminated = true
      let subs = Array(state.subscribers.values)
      state.subscribers.removeAll()
      if !subs.isEmpty {
        scheduleReconciliation()
      }
      return subs
    }
    for sub in snapshot {
      sub.continuation.finish()
    }
  }

  /// Permanently terminates the broadcaster, then waits until queued
  /// lifecycle callbacks have completed.
  ///
  /// This is for teardown paths where the upstream resource is about to
  /// be destroyed and `onLastUnsubscribed` must have run before the
  /// caller continues. Do not call it from a lifecycle callback.
  func terminateAndWaitForLifecycleCallbacks() {
    terminate()
    reconciliation.drain()
  }

  private func unsubscribe(id: Int) {
    state.withLock { state in
      let wasEmpty = state.subscribers.isEmpty
      state.subscribers.removeValue(forKey: id)
      if !wasEmpty, state.subscribers.isEmpty {
        scheduleReconciliation()
      }
    }
  }

  // MARK: - Lifecycle reconciliation

  /// Must be called while holding the `state` lock (see the comment in
  /// `subscribe`): scheduling inside the critical section keeps the FIFO
  /// queue's job order consistent with the order of membership
  /// transitions.
  private func scheduleReconciliation() {
    reconciliation.schedule { [weak self] in
      self?.runReconciliation()
    }
  }

  /// Converges the upstream attachment to the current membership.
  ///
  /// Runs only on the serial reconciliation queue, so passes never
  /// overlap and `attached` flips strictly between callbacks — a
  /// double-attach or double-detach is impossible regardless of how
  /// subscribe/unsubscribe storms interleave with the queue. Each pass
  /// loops until attachment matches membership, so a membership change
  /// that lands mid-callback is absorbed by the same pass (a later
  /// queued pass then finds nothing to do).
  private func runReconciliation() {
    while true {
      let shouldAttach = state.withLock { state -> Bool? in
        let desired = !state.subscribers.isEmpty
        return desired == state.attached ? nil : desired
      }
      guard let shouldAttach else { return }

      if shouldAttach {
        onFirstSubscriber()
      } else {
        onLastUnsubscribed()
      }
      state.withLock { $0.attached = shouldAttach }
    }
  }
}

/// Serial async dispatch of lifecycle reconciliation work.
///
/// Wraps a `DispatchQueue` so reconciliation cannot race with itself
/// across rapid subscribe/unsubscribe storms. The queue is private to
/// each `Broadcaster` instance, so different broadcasters reconcile
/// independently.
private final class ReconciliationQueue: Sendable {
  private let queue = DispatchQueue(label: "swiftvlc.broadcaster.reconciliation")

  func schedule(_ work: @escaping @Sendable () -> Void) {
    queue.async(execute: work)
  }

  func drain() {
    queue.sync {}
  }
}
