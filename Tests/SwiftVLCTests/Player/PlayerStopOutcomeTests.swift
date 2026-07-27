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

    // MARK: - Wait logic, driven without live playback

    //
    // CI cannot reach `.playing` (`TestCondition.canPlayMedia`), so the
    // decision logic is exercised directly against a synthetic event stream.
    // These cover the branches the playback tests can only reach on a
    // developer machine.

    /// A stop for the awaited handle ends the wait as output-safe.
    @Test
    func `A stopped event for the awaited source reports stopped`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(source: 7, event: .stateChanged(.stopped))
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        source: 7,
        timeout: .seconds(5)
      )

      #expect(outcome == .stopped)
    }

    /// The core of the fix: an error is not a stop. It must not end the wait,
    /// so a stream carrying only an error times out rather than reporting the
    /// outputs released.
    @Test
    func `An error event alone never reports output-safe`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(source: 7, event: .stateChanged(.error))
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        source: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
      #expect(!outcome.isOutputSafe)
    }

    /// An error followed by the stop that actually releases the outputs is
    /// the real libVLC ordering, and must resolve as output-safe.
    @Test
    func `An error followed by a stop reports stopped`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(source: 7, event: .stateChanged(.error)),
        SourcedPlayerEvent(source: 7, event: .stateChanged(.stopped))
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        source: 7,
        timeout: .seconds(5)
      )

      #expect(outcome == .stopped)
    }

    /// A stop belonging to a different native handle must be ignored: it says
    /// nothing about the handle this caller is waiting on.
    @Test
    func `A stop from another source is ignored`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(source: 99, event: .stateChanged(.stopped))
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        source: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
    }

    /// Non-state events must not be mistaken for a terminal transition.
    @Test
    func `Unrelated events do not end the wait`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(source: 7, event: .timeChanged(.seconds(1))),
        SourcedPlayerEvent(source: 7, event: .stateChanged(.playing))
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        source: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
    }

    /// Nothing arriving at all resolves as a timeout rather than hanging.
    @Test
    func `An empty stream times out`() async {
      let stream = Self.eventStream([])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        source: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
    }

    /// A ceiling reached while the handle sits in error is reported as the
    /// error it is, not as a bare timeout — the two mean different things to
    /// a caller deciding whether to retry or surface a failure.
    @Test
    func `A timeout with the handle in error reports failedButStillDraining`() {
      #expect(
        Player.resolveStopOutcome(waitOutcome: .timedOut, nativeState: .error)
          == .failedButStillDraining
      )
    }

    /// A timeout with no error stays a timeout.
    @Test
    func `A timeout without an error stays a timeout`() {
      #expect(
        Player.resolveStopOutcome(waitOutcome: .timedOut, nativeState: .stopped)
          == .timedOut
      )
      #expect(
        Player.resolveStopOutcome(waitOutcome: .timedOut, nativeState: .playing)
          == .timedOut
      )
    }

    /// An observed stop is output-safe regardless of what the handle reports
    /// afterwards — the release already happened.
    @Test
    func `An observed stop is never downgraded`() {
      #expect(
        Player.resolveStopOutcome(waitOutcome: .stopped, nativeState: .error)
          == .stopped
      )
      #expect(
        Player.resolveStopOutcome(waitOutcome: .stopped, nativeState: .stopped)
          == .stopped
      )
    }

    /// Builds a finite stream of the given events. The stream finishes after
    /// the last one, which also exercises the "source ended without a stop"
    /// path.
    private static func eventStream(
      _ events: [SourcedPlayerEvent]
    )
      -> AsyncStream<SourcedPlayerEvent> {
      AsyncStream { continuation in
        for event in events {
          continuation.yield(event)
        }
        continuation.finish()
      }
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
