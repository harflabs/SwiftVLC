import Dispatch
import os
import Synchronization

/// A multi-consumer broadcaster of `Sendable` values.
///
/// Each call to ``subscribe(bufferSize:filter:)`` returns an
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
    var lifecyclePending: LifecyclePhase = .idle
    /// Once `true`, the broadcaster is permanently terminated. New
    /// `subscribe(...)` calls return immediately-finished streams and
    /// `broadcast(_:)` is a no-op. Set by ``terminate()``.
    var terminated: Bool = false
  }

  /// Tracks reconciliation work so first-subscribe and last-unsubscribe
  /// callbacks fire exactly once per transition without overlapping.
  private enum LifecyclePhase {
    case idle // last reconciliation matches the current state
    case scheduledOn // a 0→N transition needs to fire `onFirstSubscriber`
    case scheduledOff // an N→0 transition needs to fire `onLastUnsubscribed`
    case running // a reconciliation pass is currently executing
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
  ///   - bufferSize: Override the broadcaster's default buffer size for
  ///     this stream. The buffering policy is always `.bufferingNewest`.
  ///   - filter: Optional per-subscriber predicate. Only elements for
  ///     which `filter` returns `true` are yielded to this stream.
  func subscribe(
    bufferSize: Int? = nil,
    filter: Filter? = nil
  ) -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream<Element>.makeStream(
      bufferingPolicy: .bufferingNewest(bufferSize ?? defaultBufferSize)
    )

    let outcome = state.withLock { state -> (id: Int, becameFirst: Bool)? in
      guard !state.terminated else { return nil }
      let id = state.nextID
      state.nextID += 1
      state.subscribers[id] = Subscriber(continuation: continuation, filter: filter)
      let becameFirst = state.subscribers.count == 1
      if becameFirst {
        state.lifecyclePending = .scheduledOn
      }
      return (id, becameFirst)
    }

    guard let outcome else {
      continuation.finish()
      return stream
    }

    continuation.onTermination = { [weak self] _ in
      self?.unsubscribe(id: outcome.id)
    }

    if outcome.becameFirst {
      reconciliation.schedule { [weak self] in
        self?.runFirstSubscriberCallback()
      }
    }

    return stream
  }

  /// Sends an element to every subscriber whose filter accepts it.
  ///
  /// Safe to call from any thread, including from a libVLC C callback.
  /// Subscriber filters and yields run outside the broadcaster's lock,
  /// so a slow consumer can't block other consumers or the producer.
  func broadcast(_ element: Element) {
    let interval = Signposts.signposter.beginInterval("Broadcaster.broadcast")
    let snapshot = state.withLock { state in
      state.terminated
        ? []
        : state.subscribers.values.filter { sub in
          sub.filter?(element) ?? true
        }
    }
    for sub in snapshot {
      sub.continuation.yield(element)
    }
    Signposts.signposter.endInterval("Broadcaster.broadcast", interval, "subs=\(snapshot.count)")
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

  /// Returns `true` if there is at least one subscriber, regardless of
  /// any filters. Cheaper than ``hasSubscriber(matching:)`` when you
  /// only need to know whether anyone is listening.
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
    let (snapshot, becameEmpty) = state.withLock { state -> ([Subscriber], Bool) in
      let subs = Array(state.subscribers.values)
      let wasEmpty = state.subscribers.isEmpty
      state.subscribers.removeAll()
      let becameEmpty = !wasEmpty
      if becameEmpty {
        state.lifecyclePending = .scheduledOff
      }
      return (subs, becameEmpty)
    }
    for sub in snapshot {
      sub.continuation.finish()
    }
    if becameEmpty {
      reconciliation.schedule { [weak self] in
        self?.runLastUnsubscribedCallback()
      }
    }
  }

  /// Permanently terminates the broadcaster.
  ///
  /// Finishes every active stream, makes future calls to
  /// ``subscribe(bufferSize:filter:)`` return immediately-finished
  /// streams, and makes ``broadcast(_:)`` a no-op. `onLastUnsubscribed`
  /// fires on the reconciliation queue if there were active subscribers.
  ///
  /// Use when the broadcaster's underlying source is gone for good
  /// (handler deinit, registration loss). For temporary teardown where
  /// new subscribers might re-attach, use ``finishAll()`` instead.
  func terminate() {
    let (snapshot, becameEmpty) = state.withLock { state -> ([Subscriber], Bool) in
      state.terminated = true
      let subs = Array(state.subscribers.values)
      let wasEmpty = state.subscribers.isEmpty
      state.subscribers.removeAll()
      let becameEmpty = !wasEmpty
      if becameEmpty {
        state.lifecyclePending = .scheduledOff
      }
      return (subs, becameEmpty)
    }
    for sub in snapshot {
      sub.continuation.finish()
    }
    if becameEmpty {
      reconciliation.schedule { [weak self] in
        self?.runLastUnsubscribedCallback()
      }
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
    let becameEmpty = state.withLock { state -> Bool in
      let wasEmpty = state.subscribers.isEmpty
      state.subscribers.removeValue(forKey: id)
      return !wasEmpty && state.subscribers.isEmpty
    }
    if becameEmpty {
      state.withLock { $0.lifecyclePending = .scheduledOff }
      reconciliation.schedule { [weak self] in
        self?.runLastUnsubscribedCallback()
      }
    }
  }

  // MARK: - Lifecycle reconciliation

  private func runFirstSubscriberCallback() {
    let shouldFire = state.withLock { state -> Bool in
      guard state.lifecyclePending == .scheduledOn, !state.subscribers.isEmpty else {
        state.lifecyclePending = .idle
        return false
      }
      state.lifecyclePending = .running
      return true
    }
    guard shouldFire else { return }

    onFirstSubscriber()

    state.withLock { state in
      // If subscribers vanished while the callback ran, schedule the
      // teardown so we leave no upstream attachment behind.
      if state.subscribers.isEmpty {
        state.lifecyclePending = .scheduledOff
      } else {
        state.lifecyclePending = .idle
      }
    }
    let needsTeardown = state.withLock { $0.lifecyclePending == .scheduledOff }
    if needsTeardown {
      reconciliation.schedule { [weak self] in
        self?.runLastUnsubscribedCallback()
      }
    }
  }

  private func runLastUnsubscribedCallback() {
    let shouldFire = state.withLock { state -> Bool in
      guard state.lifecyclePending == .scheduledOff, state.subscribers.isEmpty else {
        state.lifecyclePending = .idle
        return false
      }
      state.lifecyclePending = .running
      return true
    }
    guard shouldFire else { return }

    onLastUnsubscribed()

    state.withLock { state in
      // If subscribers reattached while the teardown callback ran,
      // schedule a reattach so we don't leave the broadcaster in a
      // detached state with active subscribers.
      if !state.subscribers.isEmpty {
        state.lifecyclePending = .scheduledOn
      } else {
        state.lifecyclePending = .idle
      }
    }
    let needsAttach = state.withLock { $0.lifecyclePending == .scheduledOn }
    if needsAttach {
      reconciliation.schedule { [weak self] in
        self?.runFirstSubscriberCallback()
      }
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
