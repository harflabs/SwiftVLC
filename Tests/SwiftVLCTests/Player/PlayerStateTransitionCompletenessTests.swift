@testable import SwiftVLC
import Synchronization
import Testing

extension Integration {
  /// `stateTransitions` is documented as a lossless lifecycle stream, but it
  /// was built by filtering raw `.stateChanged` events — and libVLC reports a
  /// native failure as `.encounteredError` and buffering as
  /// `.bufferingProgress`. Neither ever produced a `.stateChanged`, so every
  /// transition to `.error` and `.buffering` was silently absent.
  ///
  /// That is not only a gap in the stream. `recast(to:)` waits on this stream
  /// for `.playing || .error`, so a replacement session that failed could
  /// never be observed failing: the wait ran to its full ten-second ceiling
  /// and reported `.timedOut`, which is both slow and the wrong answer.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PlayerStateTransitionCompletenessTests {
    /// `Mutex` is noncopyable, so the collector cannot be factored into a
    /// helper that returns it alongside its task — each test builds its own.
    @Test(.timeLimit(.minutes(1)))
    func `A native error reaches the transition stream`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)
      let transitions = player.stateTransitions
      let collected = Mutex<[PlayerState]>([])
      let collector = Task.detached { @Sendable in
        for await state in transitions {
          collected.withLock { $0.append(state) }
        }
      }

      bridge._broadcastForTesting(.encounteredError, source: source)

      try #require(
        await poll(until: { collected.withLock { $0.contains(.error) } }),
        "the error transition never reached stateTransitions"
      )
      collector.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func `Entering buffering reaches the transition stream`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)
      let transitions = player.stateTransitions
      let collected = Mutex<[PlayerState]>([])
      let collector = Task.detached { @Sendable in
        for await state in transitions {
          collected.withLock { $0.append(state) }
        }
      }

      bridge._broadcastForTesting(.bufferingProgress(0.25), source: source)

      try #require(
        await poll(until: { collected.withLock { $0.contains(.buffering) } }),
        "the buffering transition never reached stateTransitions"
      )
      collector.cancel()
    }

    /// Completeness must not cost the no-firehose guarantee. Buffering
    /// progress arrives at the fill rate; only *entering* buffering is a
    /// transition, so repeated reports must not re-announce it.
    @Test(.timeLimit(.minutes(1)))
    func `Buffering progress does not re-announce the state`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)
      let transitions = player.stateTransitions
      let collected = Mutex<[PlayerState]>([])
      let collector = Task.detached { @Sendable in
        for await state in transitions {
          collected.withLock { $0.append(state) }
        }
      }

      for index in 0..<200 {
        bridge._broadcastForTesting(.bufferingProgress(Float(index) / 200), source: source)
      }
      // Bounds the drain: once this lands, every buffering report before it
      // has been processed.
      bridge._broadcastForTesting(.stateChanged(.playing), source: source)

      try #require(
        await poll(until: { collected.withLock { $0.contains(.playing) } }),
        "Waiting for: the sentinel transition"
      )
      collector.cancel()

      let bufferingCount = collected.withLock { $0.filter { $0 == .buffering }.count }
      #expect(bufferingCount == 1, "200 progress reports produced \(bufferingCount) transitions")
    }

    /// Completeness is worth nothing if the stream then drops what it
    /// collected. `Broadcaster.subscribe()` defaults to newest-64, so moving
    /// this stream onto a broadcaster is one keyword away from silently
    /// turning a lossless API lossy — which is how it was written first.
    ///
    /// The transitions are published *before* the stream is drained, so they
    /// all sit in the subscriber's buffer at once. That is the condition a
    /// bounded policy truncates and an unbounded one does not.
    @Test(.timeLimit(.minutes(1)))
    func `A backlog past the default buffer size is not truncated`() async {
      let player = Player(instance: TestInstance.shared)
      let transitions = player.stateTransitions

      // Comfortably past `Broadcaster`'s 64-element default.
      let published = 200
      for index in 0..<published {
        player.publishPlaybackState(index.isMultiple(of: 2) ? .playing : .paused)
      }
      // Ends the drain below without depending on a timeout.
      player.stateTransitionBridge.terminate()

      var received = 0
      for await _ in transitions {
        received += 1
      }

      #expect(
        received == published,
        "\(published - received) transitions were dropped; the stream is bounded, not lossless"
      )
    }

    /// The consequence the issue is really about: the recast wait has to see
    /// a failure rather than sit out its ceiling. The timeout here is short on
    /// purpose — a regression should fail this in a second, not stall it.
    @Test(.timeLimit(.minutes(1)))
    func `The recast wait observes failure instead of timing out`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)
      // The wait is generation-scoped now, so it consumes `playbackStatus`
      // and is anchored to the player's current generation.
      let statuses = player.playbackStatus
      let generation = player.generation

      let result = Task {
        await Player.awaitPlaying(on: statuses, atLeast: generation, timeout: .seconds(5))
      }
      // Give the wait a turn to subscribe before the error is broadcast.
      await Task.yield()
      bridge._broadcastForTesting(.encounteredError, source: source)

      #expect(
        await result.value == .failed,
        "the recast wait could not observe the failure and fell through to its timeout"
      )
    }
  }
}
