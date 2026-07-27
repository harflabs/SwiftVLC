@testable import SwiftVLC
import Foundation
import Testing

/// `stopAndWait()` must report output safety truthfully.
///
/// The whole point of the API is to give callers a moment after which nothing
/// is still draining — it is what you call before
/// `AVAudioSession.setActive(false, …)` or before detaching a drawable. A
/// result that reads as success while an audio output is alive is worse than
/// no result at all, so these tests pin the cases where that could happen:
///
/// - A native error is **not** completion. libVLC emits the error first and
///   the stopped state that actually releases the outputs afterwards, so
///   returning on `.error` would promise safety mid-drain.
/// - Concurrent callers must join one stop and all see the same answer.
/// - Repeated play/stop/detach cycles must stay safe.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(2)))
  @MainActor struct PlayerStopOutcomeTests {
    /// An idle player has nothing draining, so the result is immediately
    /// output-safe.
    @Test
    func `Idle player reports an output-safe stop`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let outcome = await player.stopAndWait()

      #expect(outcome == .stopped)
      #expect(outcome.isOutputSafe)
    }

    /// An unopenable media drives libVLC to `.error`, and the `.stopped` that
    /// actually releases the outputs only arrives afterwards. This pins the
    /// invariant that falls out of no longer treating `.error` as terminal:
    /// an output-safe answer is never returned while the native handle is
    /// still sitting in error.
    ///
    /// The error is awaited as an *event* rather than polled as a resting
    /// state — libVLC moves through error to stopped faster than any poll
    /// interval reliably catches.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Native error does not report output-safe completion early`() async throws {
      let missingPath = "/nonexistent/swiftvlc-\(UUID().uuidString).mp4"
      let player = Player(instance: TestInstance.makePlayback())
      let events = player.events(policy: .unbounded, filter: nil)

      try player.play(Media(path: missingPath))

      let sawError = Task.detached { @Sendable in
        for await event in events {
          if case .encounteredError = event {
            return true
          }
          if case .stateChanged(.stopped) = event {
            return false
          }
        }
        return false
      }
      // Asserted, not discarded: if the error is never observed the player
      // took some other path and the invariant below would pass vacuously.
      try #require(
        await sawError.value,
        "the unopenable media never reported an error, so the post-error path was not exercised"
      )

      let outcome = await player.stopAndWait()

      // Either the stop landed (the normal case, since `.stopped` follows the
      // error) or we are explicitly told the drain never finished. What must
      // never happen is an output-safe answer while the handle sits in error.
      if outcome.isOutputSafe {
        #expect(
          player.nativePlaybackState != .error,
          "reported output-safe while the native handle was still in error"
        )
      } else {
        #expect(outcome == .failedButStillDraining || outcome == .timedOut)
      }
    }

    /// Concurrent callers join one in-flight stop, so none of them can be
    /// told the outputs are free on the strength of someone else's request.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Concurrent callers receive the same terminal result`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      var callers: [Task<PlayerStopOutcome, Never>] = []
      for _ in 0..<6 {
        callers.append(Task { @MainActor in await player.stopAndWait() })
      }

      var outcomes: [PlayerStopOutcome] = []
      for caller in callers {
        await outcomes.append(caller.value)
      }

      #expect(outcomes.count == 6)
      #expect(
        Set(outcomes).count == 1,
        "concurrent callers disagreed about output safety: \(outcomes)"
      )
      #expect(outcomes.first == .stopped)
    }

    /// A caller whose task is cancelled must still be told the truth. The
    /// drain is deliberately not abandoned, so the reported state stays
    /// accurate rather than becoming indistinguishable from success.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Cancelled caller still receives an accurate result`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      let caller = Task { @MainActor in await player.stopAndWait() }
      caller.cancel()
      let outcome = await caller.value

      #expect(outcome == .stopped)
      #expect(
        player.nativePlaybackState == .stopped,
        "drain was abandoned on cancellation: \(player.nativePlaybackState)"
      )
    }

    /// The result has to stay trustworthy across repeated cycles, since that
    /// is how it is used in practice: stop, tear down outputs, play again.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Repeated play and stop cycles stay output-safe`() async throws {
      let player = Player(instance: TestInstance.makePlayback())

      for cycle in 0..<3 {
        try player.play(url: TestMedia.twosecURL)
        try #require(
          await poll(until: { player.state == .playing }),
          "Waiting for: player.state == .playing (cycle \(cycle))"
        )

        let outcome = await player.stopAndWait()

        #expect(outcome == .stopped, "cycle \(cycle) was not output-safe")
        #expect(player.nativePlaybackState == .stopped, "cycle \(cycle)")
      }
    }
  }
}
