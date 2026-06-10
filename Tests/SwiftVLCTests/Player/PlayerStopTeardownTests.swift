@testable import SwiftVLC
import Foundation
import Testing

#if canImport(UIKit) && !os(macOS)
import AVFoundation
#endif

/// Synchronous-teardown guarantees of `stopAndWait()` and `shutdown()`:
/// libVLC's stop is asynchronous, so both APIs exist precisely to give
/// callers a point in time after which no native output is still
/// draining. Playback-driving tests are gated on
/// `TestCondition.canPlayMedia`; the idle / lifecycle variants run
/// everywhere, including CI.
extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerStopTeardownTests {
    /// The whole contract of `stopAndWait()` is that the suspension
    /// covers the native stop: both the observable mirror and libVLC's
    /// own state must already be terminal on return, with no polling
    /// grace period.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `stopAndWait returns only after the native stop completes`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      await player.stopAndWait()

      #expect(
        player.state == .stopped,
        "observable state not terminal immediately after stopAndWait: \(player.state)"
      )
      #expect(
        player.nativePlaybackState == .stopped,
        "native handle still draining after stopAndWait: \(player.nativePlaybackState)"
      )
    }

    /// An idle player has no stop to wait for — the terminal
    /// short-circuit must return without arming the 10-second ceiling.
    @Test(.timeLimit(.minutes(1)))
    func `stopAndWait on an idle player returns immediately`() async {
      let player = Player(instance: TestInstance.shared)

      let start = ContinuousClock.now
      await player.stopAndWait()
      let elapsed = ContinuousClock.now - start

      #expect(
        elapsed < .milliseconds(500),
        "stopAndWait suspended \(elapsed) on an idle player — terminal short-circuit regressed"
      )
    }

    /// Each cycle's await must consume exactly its own terminal event;
    /// a stale subscription or a leftover stop flag from the previous
    /// cycle would either hang an iteration or return before the stop
    /// finished.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `stopAndWait is reentrant-safe across rapid cycles`() async throws {
      let player = Player(instance: TestInstance.makePlayback())

      for cycle in 1...5 {
        try player.play(url: TestMedia.twosecURL)
        try #require(
          await poll(until: { player.state == .playing }),
          "Waiting for: player.state == .playing in cycle \(cycle)"
        )
        await player.stopAndWait()
        #expect(
          player.state == .stopped,
          "cycle \(cycle) returned before the native stop completed: \(player.state)"
        )
      }
    }

    /// After `shutdown()` the player is inert but harmless: state is
    /// reset, the media is gone, a second shutdown returns immediately,
    /// and stray `stop()` / `play()` calls on the replacement handle
    /// must not crash.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `shutdown completes teardown and is idempotent`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      await player.shutdown()
      #expect(player.state == .idle, "state not reset after shutdown: \(player.state)")
      #expect(player.currentMedia == nil, "media survived shutdown")

      await player.shutdown()
      #expect(player.state == .idle, "second shutdown disturbed the inert player: \(player.state)")

      // Stray calls after shutdown land on the replacement handle and
      // must be harmless — playback may fail or no-op, but never crash.
      player.stop()
      try? player.play(url: TestMedia.twosecURL)
      player.stop()
    }

    /// Lifecycle-only variant: shutting down a player that never played
    /// must complete and stay idempotent without any playback machinery.
    @Test(.timeLimit(.minutes(1)))
    func `shutdown on a fresh player completes and is idempotent`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      await player.shutdown()
      #expect(player.state == .idle, "state not reset after shutdown: \(player.state)")
      #expect(player.currentMedia == nil)

      await player.shutdown()
      #expect(player.state == .idle, "second shutdown disturbed the inert player: \(player.state)")
    }

    /// `shutdown()` must leave nothing alive that pins the player —
    /// the event-consumer task, the intent bridge, and the offloaded
    /// teardown closure all hold (or held) references that would keep
    /// the weak probe non-nil if any of them survived.
    @Test(.timeLimit(.minutes(1)))
    func `shutdown leaves no live player references`() async throws {
      weak var probe: Player?
      do {
        let player = Player(instance: TestInstance.makeAudioOnly())
        probe = player
        await player.shutdown()
      }

      try #require(
        await poll(until: { probe == nil }),
        "Waiting for: player released after shutdown"
      )
    }

    #if canImport(UIKit) && !os(macOS)
    /// The motivating use case: deactivating a shared `AVAudioSession`
    /// fails session-busy while libVLC's audio output is still alive.
    /// After `stopAndWait()` returns, deactivation must succeed on the
    /// first try.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `stopAndWait drains the audio output before session deactivation`() async throws {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback)
      try session.setActive(true)

      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      await player.stopAndWait()

      #expect(throws: Never.self, "session deactivation raced the audio-output drain") {
        try AVAudioSession.sharedInstance().setActive(
          false,
          options: .notifyOthersOnDeactivation
        )
      }
    }
    #endif
  }
}
