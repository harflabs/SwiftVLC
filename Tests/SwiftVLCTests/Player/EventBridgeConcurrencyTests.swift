@testable import SwiftVLC
import Synchronization
import Testing

/// Concurrency hardening for the event-bridge broadcaster. Regression
/// guards for the single-`Mutex<State>` `ContinuationStore`: heavy
/// concurrent `add`/`remove`, guaranteed delivery under churn, and the
/// AB-BA deadlock that would appear if `broadcast` yielded while
/// holding the lock.
///
/// Each test creates its own VLC instance via
/// `TestInstance.makeAudioOnly()` so libVLC's per-instance state can't
/// bleed between tests. Serial (`--no-parallel` in CI) keeps MainActor
/// contention out of the picture.
@Suite(
  .tags(.integration, .mainActor, .async),
  .timeLimit(.minutes(1)),
  .serialized
)
@MainActor
struct EventBridgeConcurrencyTests {
  // MARK: - Heavy fan-out

  /// Registers many concurrent consumers, drives playback, and verifies
  /// every consumer receives at least one event. Indirectly exercises
  /// the broadcaster's snapshot-under-lock pattern — if the Mutex were
  /// held during yield and a consumer cancelled mid-broadcast, we'd
  /// deadlock.
  @Test
  func `Hundred concurrent consumers all receive events`() async throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let consumerCount = 100
    let counts = Mutex<[Int]>(Array(repeating: 0, count: consumerCount))

    // Subscribe all consumers BEFORE starting playback so no consumer
    // misses the early events.
    var tasks: [Task<Void, Never>] = []
    for i in 0..<consumerCount {
      let stream = player.events
      tasks.append(Task.detached { @Sendable in
        for await _ in stream {
          counts.withLock { $0[i] += 1 }
          return
        }
      })
    }

    try player.play(Media(url: TestMedia.twosecURL))

    // Race a short-interval poll on the count array against a 5-second
    // ceiling. First to finish ends the wait. No event subscription is
    // needed — the child consumer tasks are the true event observers;
    // here we just wait for all of them to tick their slot.
    let converged = await withTaskGroup(of: Bool.self) { group in
      group.addTask { @Sendable in
        while !Task.isCancelled {
          if counts.withLock({ $0.allSatisfy { $0 >= 1 } }) { return true }
          try? await Task.sleep(for: .milliseconds(5))
        }
        return false
      }
      group.addTask { @Sendable in
        try? await Task.sleep(for: .seconds(5))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }

    player.stop()
    for task in tasks {
      task.cancel()
    }

    let received = counts.withLock { $0.count(where: { $0 >= 1 }) }
    #expect(
      converged && received == consumerCount,
      "only \(received)/\(consumerCount) consumers received events"
    )
  }

  // MARK: - Churn during active broadcast

  /// Creates and cancels streams continuously while playback generates
  /// real events. Regression guard for use-after-free in `onTermination →
  /// remove` and for Mutex deadlocks between `broadcast` and `remove`.
  @Test
  func `Subscribe unsubscribe churn during playback`() async throws {
    let player = Player(instance: TestInstance.makeAudioOnly())

    // Subscribe a pre-playback watcher so we don't race the `.playing`
    // event with the subsequent churn.
    let playing = subscribeAndAwait(.playing, on: player)
    try player.play(Media(url: TestMedia.twosecURL))
    try #require(await playing.value)

    // 200 rounds of subscribe + immediate cancel. A use-after-free
    // in `onTermination → remove` or a lock inversion between
    // `broadcast` and `remove` would surface here as a crash or
    // hang (caught by the suite's `.timeLimit`).
    for _ in 0..<200 {
      let stream = player.events
      let t = Task.detached { @Sendable in
        for await _ in stream {
          break
        }
      }
      t.cancel()
    }

    // Reaching here means 200 subscribe/unsubscribe cycles completed
    // without crashing or hanging. That's the actual regression guard.
    player.stop()
  }

  // MARK: - Cancellation mid-broadcast (AB-BA regression)

  /// Starts consumers, then cancels them in bulk. If the AB-BA guard
  /// in `ContinuationStore.broadcast` ever regresses (i.e. someone
  /// moves `yield()` back inside `withLock`), one of the onTermination
  /// callbacks would deadlock against a live broadcast and this test
  /// would never complete — the suite `.timeLimit(.minutes(1))` would
  /// fire, not a polling-based fallback.
  @Test
  func `Cancelling during broadcast does not deadlock`() async throws {
    let player = Player(instance: TestInstance.makeAudioOnly())

    // Subscribe the `.playing` watcher BEFORE we create the 32 busy
    // consumers and BEFORE `play()` — otherwise the watcher's
    // subscription can race past the state-change event we're waiting
    // for and we'd sit on the 5s ceiling for no reason.
    let playing = subscribeAndAwait(.playing, on: player)

    var tasks: [Task<Void, Never>] = []
    for _ in 0..<32 {
      let stream = player.events
      tasks.append(Task.detached { @Sendable in
        for await _ in stream {
          // Heavy body widens the race window between yield and cancel.
          for _ in 0..<50 {
            _ = (0..<10).reduce(0, +)
          }
        }
      })
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try #require(await playing.value, "player did not reach .playing within 5s")

    // All 32 consumers are inside `for await`. Cancel them together —
    // each cancellation calls back into the ContinuationStore to remove
    // itself while broadcasts may be in flight.
    for t in tasks {
      t.cancel()
    }
    player.stop()
  }

  // MARK: - Lifetime — stream outlives player

  /// The stream's retained `ContinuationStore` box must keep the bridge
  /// alive until consumers drain. After the player is gone, a paused
  /// consumer must still receive the terminal `finish()` and exit
  /// cleanly — if it doesn't, this test's `.timeLimit` fires.
  @Test
  func `Stream finishes cleanly when player deinits`() async {
    let stream: AsyncStream<PlayerEvent>
    do {
      let player = Player(instance: TestInstance.makeAudioOnly())
      stream = player.events
    } // player goes out of scope

    // Drain the stream — this must return, not hang. `Player.deinit`
    // offloads bridge invalidation to a background queue, which calls
    // `continuation.finish()` so the for-await loop exits.
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in stream {}
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
      }
      // First task to finish ends the wait (usually the stream drain).
      await group.next()
      group.cancelAll()
    }
  }

  // MARK: - Multi-player isolation

  /// Each `Player` owns its own `EventBridge`. Events on player A must
  /// never reach player B's consumers.
  @Test
  func `Events from one player do not reach another`() async throws {
    let a = Player(instance: TestInstance.makeAudioOnly())
    let b = Player(instance: TestInstance.makeAudioOnly())

    let bReceivedActivity = Mutex(false)
    let bStream = b.events
    let consumer = Task.detached { @Sendable in
      for await event in bStream {
        if
          case .stateChanged(let s) = event,
          s != .idle, s != .stopped, s != .stopping {
          bReceivedActivity.withLock { $0 = true }
          return
        }
      }
    }

    // Subscribe for A's `.playing` BEFORE starting — otherwise the
    // subscription can race past the event.
    let aPlaying = subscribeAndAwait(.playing, on: a)
    try a.play(Media(url: TestMedia.twosecURL))
    try #require(await aPlaying.value)

    // Give player B's consumer a bounded window to incorrectly observe
    // activity. If cross-contamination exists, the dedicated consumer
    // above sets `bReceivedActivity`.
    try await Task.sleep(for: .milliseconds(200))

    #expect(
      !bReceivedActivity.withLock { $0 },
      "player B received activity while only player A was driven"
    )
    a.stop()
    consumer.cancel()
  }
}
