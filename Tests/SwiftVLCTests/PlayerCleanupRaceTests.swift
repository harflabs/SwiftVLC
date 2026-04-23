@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// Probes the `Player.deinit` offload path to see if rapid re-entry on a
/// shared `VLCInstance` plus a concurrent utility-queue drain corrupts
/// libVLC's internal state.
///
/// The offload path in `Sources/SwiftVLC/Player/Player.swift:324-343`
/// moves `bridge.invalidate()`, `libvlc_media_player_stop_async(p)`, and
/// `libvlc_media_player_release(p)` to `DispatchQueue.global(qos:
/// .utility)`. That queue is **concurrent**, so multiple deinits observed
/// in rapid succession (e.g. a user navigating in and out of case
/// studies) can race one another, and also race new players being built
/// on the same instance. libVLC's release path (`lib/media_player.c:871`)
/// takes `vlc_player_Lock(p_mi->player)` over its own player, removes the
/// aout listener, and calls `libvlc_release(instance)` at the tail; each
/// player's locks are distinct, so in principle the concurrent releases
/// are safe, but the shared audio-output subsystem (reference-counted on
/// the instance) is the likely contention point.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(5)), .serialized)
  @MainActor struct PlayerCleanupRaceTests {
    // MARK: - a) Staggered spawn across 16 tasks on the shared instance

    /// Spawns 16 concurrent tasks, each of which creates / plays / stops
    /// / drops a `Player` on `TestInstance.shared` ten times with a
    /// 1ms-staggered start. The stagger keeps launches overlapping so the
    /// utility queue sees a continuous stream of in-flight cleanups while
    /// new players are being built on the same instance.
    ///
    /// If the offloaded `invalidate() → stop_async → release` sequence is
    /// racy against a fresh player's attach path, this surfaces as a
    /// crash, an EXC_BAD_ACCESS, or a deadlock (test timeout).
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Sixteen tasks churning players on shared instance do not crash`() async throws {
      let instance = TestInstance.shared

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
          group.addTask { @MainActor in
            for _ in 0..<10 {
              let player = Player(instance: instance)
              try? player.play(url: TestMedia.twosecURL)
              player.stop()
            }
          }
        }
        await group.waitForAll()
      }

      // Poll several seconds so every offloaded closure has time to run
      // invalidate + stop_async + release before the test exits. A hang
      // here would surface as the enclosing `.timeLimit` firing.
      try await Task.sleep(for: .seconds(3))
      await yield(64)
    }

    // MARK: - b) 32 players released simultaneously

    /// Builds 32 players in a tight loop, drives each toward playback,
    /// then drops the array in one go. Every `deinit` fires in the same
    /// main-actor tick and floods the utility queue with 32 concurrent
    /// cleanup closures contending for libVLC's shared instance state.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Thirty-two simultaneous player drops do not crash`() async throws {
      let instance = TestInstance.shared
      let probes = WeakProbes()

      do {
        var players: [Player] = []
        players.reserveCapacity(32)
        for _ in 0..<32 {
          let p = Player(instance: instance)
          probes.add(p)
          try? p.play(url: TestMedia.twosecURL)
          players.append(p)
        }
        // All 32 deinits fire when `players` leaves this scope. The
        // utility queue sees the full cleanup burst at once.
        _ = players
      }

      try await Task.sleep(for: .seconds(3))
      await yield(64)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / 32 Players leaked after a simultaneous-drop burst")
    }

    // MARK: - c) Re-entry faster than the utility queue drains

    /// Creates a player, plays, drops — then immediately creates a new
    /// player on the *same* instance before the previous cleanup has any
    /// chance to finish. 50 iterations at ~50ms each pile up 50 pending
    /// `release` calls ahead of the next-spawned player. If libVLC's
    /// instance-level state (audio output pool, module refcounts) isn't
    /// race-safe under that pressure, this is the canonical repro.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Re-entering faster than utility queue drains stays stable`() async throws {
      let instance = TestInstance.shared
      let probes = WeakProbes()
      let iterations = 50

      for _ in 0..<iterations {
        do {
          let player = Player(instance: instance)
          probes.add(player)
          try? player.play(url: TestMedia.twosecURL)
          // Let libVLC start the decode threads; short enough that
          // cleanup for the *previous* iteration is still pending.
          try? await Task.sleep(for: .milliseconds(50))
          player.stop()
        }
        // Drop occurs at end of the `do` scope; no stop-wait, so the
        // next iteration starts before the previous cleanup drains.
      }

      try await Task.sleep(for: .seconds(5))
      await yield(128)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / \(iterations) Players leaked after re-entry churn")
    }

    // MARK: - d) Interleaved Media allocations

    /// Allocates a `Media`, attaches it to a player, plays, and drops in
    /// reverse order so the player deinit fires before the media's last
    /// reference is gone. libVLC's `media_player_destroy` calls
    /// `libvlc_media_release(p_mi->p_md)` (lib/media_player.c:887); if
    /// the Swift-side drop ordering hands the player's native cleanup to
    /// the utility queue while the main actor is still holding the Media,
    /// the ordering inversion could race the media's own refcount.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Player and Media release racing does not crash`() async throws {
      let instance = TestInstance.shared
      let iterations = 24

      for _ in 0..<iterations {
        do {
          let media = try Media(url: TestMedia.twosecURL)
          let player = Player(instance: instance)
          try? player.play(media)
          // Explicitly drop the player first (its deinit dispatches),
          // then the media. The media's `libvlc_media_release` on the
          // main actor runs concurrently with the player's offloaded
          // `libvlc_media_player_release` inside media_player.c:887.
          _ = player
          _ = media
        }
      }

      try await Task.sleep(for: .seconds(3))
      await yield(64)
    }

    // MARK: - e) Drop one player while another actively plays

    /// Starts P1, waits for `.playing`, starts P2, waits for `.playing`,
    /// drops P1 while P2 is still live on the same instance. The
    /// offloaded cleanup for P1 runs on the utility queue while P2's
    /// decode threads are active against the same `libvlc_instance_t`
    /// and potentially the same audio-output subsystem.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Drop while another player on same instance is playing`() async throws {
      let instance = TestInstance.shared

      for _ in 0..<6 {
        let p2: Player = try await {
          let p1 = Player(instance: instance)
          let p1Playing = subscribeAndAwait(.playing, on: p1, timeout: .seconds(3))
          try p1.play(url: TestMedia.twosecURL)
          _ = await p1Playing.value

          let p2 = Player(instance: instance)
          let p2Playing = subscribeAndAwait(.playing, on: p2, timeout: .seconds(3))
          try p2.play(url: TestMedia.twosecURL)
          _ = await p2Playing.value

          // p1 leaves scope when the closure returns — its deinit fires
          // while p2 is still in `.playing`.
          return p2
        }()

        try await Task.sleep(for: .milliseconds(200))
        p2.stop()
        try await Task.sleep(for: .milliseconds(200))
      }

      try await Task.sleep(for: .seconds(3))
      await yield(64)
    }

    // MARK: - Helpers

    private func yield(_ n: Int) async {
      for _ in 0..<n {
        await Task.yield()
      }
    }
  }
}

// MARK: - Weak probe

@MainActor
private final class WeakProbes {
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
