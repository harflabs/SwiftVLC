@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// Teardown-path races that reproduce without any playback, so they run
/// under `CI=true` and therefore under the TSan/ASan jobs in
/// `sanitize.yml`. The playback-driven race suites are gated on
/// `TestCondition.canPlayMedia` and self-skip on CI, which leaves the
/// stop path, the native-handle swap, the offloaded `isolated deinit`,
/// and EventBridge attach/detach churn invisible to the sanitizers;
/// each test here drives one of those surfaces with lifecycle-only
/// players that never reach `.playing`.
extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PlaybackFreeTeardownRaceTests {
    // MARK: - EventBridge attach/detach churn

    /// Creates a player, fans out several event streams to detached
    /// consumers, cancels half of them mid-await, and lets the player
    /// deinit with the rest still consuming — twenty times over. The
    /// offloaded `bridge.invalidate()` must detach the C callbacks and
    /// finish every remaining stream without racing the consumers or
    /// the next iteration's fresh attach. A second phase hammers
    /// subscribe/cancel against one live player from eight concurrent
    /// tasks.
    @Test(.timeLimit(.minutes(1)))
    func `Event stream churn across player deinit does not race`() async {
      for _ in 0..<20 {
        var consumers: [Task<Void, Never>] = []
        do {
          let player = Player(instance: TestInstance.shared)
          for _ in 0..<4 {
            let stream = player.events
            consumers.append(Task.detached { @Sendable in
              for await _ in stream {}
            })
          }
          await Task.yield()
          for (index, consumer) in consumers.enumerated() where index.isMultiple(of: 2) {
            consumer.cancel()
          }
        }
        for consumer in consumers {
          await consumer.value
        }
      }

      let player = Player(instance: TestInstance.shared)
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
          group.addTask { @Sendable in
            for _ in 0..<10 {
              let stream = player.events
              let consumer = Task.detached { @Sendable in
                for await _ in stream {}
              }
              await Task.yield()
              consumer.cancel()
            }
          }
        }
        await group.waitForAll()
      }
      // Keep the player alive past the churn so deinit does not overlap it.
      withExtendedLifetime(player) {}
    }

    // MARK: - Native-handle swap without playback

    /// Reaches `replaceNativePlayerForDrawablePlayback` without media:
    /// hosting a drawable and then stopping flags the native player for
    /// replacement, so the next `prepareDrawableForPlayback()` performs
    /// the swap — fresh handle, event-bridge reattach, offloaded
    /// release of the old handle. Ten cycles with one consumer live
    /// across all of them; the stream must survive every reattach and
    /// still finish when the player deinits through the bridge's final
    /// attachment.
    @Test(.timeLimit(.minutes(1)))
    func `Repeated native handle swaps keep the event stream wired`() async throws {
      let finished = Mutex(false)
      var consumer: Task<Void, Never>?
      do {
        let player = Player(instance: TestInstance.makeAudioOnly())
        let stream = player.events
        consumer = Task.detached { @Sendable in
          for await _ in stream {}
          finished.withLock { $0 = true }
        }

        for _ in 0..<10 {
          let oldPointer = player.pointer
          player.setDrawable(NSObject())
          player.stop()
          try player.prepareDrawableForPlayback()
          #expect(
            player.pointer != oldPointer,
            "swap did not replace the native player handle"
          )
        }
        #expect(
          !finished.withLock { $0 },
          "event stream finished mid-swap instead of surviving reattach"
        )
      }

      let drained = try await poll(timeout: .seconds(5)) { finished.withLock { $0 } }
      #expect(drained, "event stream did not finish after deinit of a swapped player")
      consumer?.cancel()
    }

    // MARK: - Offloaded deinit completion

    /// Drops sixteen players — each with a hosted drawable, a live
    /// stream, and a stop, so the deinit has the richest state to tear
    /// down — then polls until every weak probe clears and sleeps long
    /// enough for the offloaded utility-queue cleanup (`invalidate()`,
    /// native stop, `libvlc_media_player_release`) to drain while the
    /// sanitizer watches.
    @Test(.timeLimit(.minutes(1)))
    func `Offloaded deinit completes for every dropped player`() async throws {
      let probes = WeakPlayerProbes()
      do {
        for _ in 0..<16 {
          let player = Player(instance: TestInstance.shared)
          probes.add(player)
          _ = player.events
          player.setDrawable(NSObject())
          player.stop()
        }
      }

      let cleared = try await poll(timeout: .seconds(5)) { probes.aliveCount() == 0 }
      #expect(cleared, "\(probes.aliveCount()) / 16 Players still alive after drop")
      try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Deinit during active consumption

    /// Verifies the deinit-time `finishAll()` reaches consumers that
    /// are provably suspended inside `for await` when the player goes
    /// away: each iteration waits until all three consumers have
    /// started before dropping the player, then requires every stream
    /// to finish.
    @Test(.timeLimit(.minutes(1)))
    func `Deinit while consumers are mid-await finishes every stream`() async throws {
      for _ in 0..<20 {
        let started = Mutex(0)
        var consumers: [Task<Void, Never>] = []
        do {
          let player = Player(instance: TestInstance.shared)
          for _ in 0..<3 {
            let stream = player.events
            consumers.append(Task.detached { @Sendable in
              started.withLock { $0 += 1 }
              for await _ in stream {}
            })
          }
          let allStarted = try await poll(timeout: .seconds(3)) { started.withLock { $0 } == 3 }
          #expect(allStarted, "consumers did not start before the player dropped")
        }
        for consumer in consumers {
          await consumer.value
        }
      }
    }
  }
}

// MARK: - Weak probe

@MainActor
private final class WeakPlayerProbes {
  private struct Probe { weak var object: Player? }
  private var probes: [Probe] = []

  func add(_ object: Player) {
    probes.append(Probe(object: object))
  }

  func aliveCount() -> Int {
    probes = probes.filter { $0.object != nil }
    return probes.count
  }
}
