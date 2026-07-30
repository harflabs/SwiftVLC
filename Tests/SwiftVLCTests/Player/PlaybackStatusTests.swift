@testable import SwiftVLC
import Testing

extension Integration {
  /// ``Player/playbackStatus`` answers what ``Player/stateTransitions`` cannot:
  /// which media session a state belongs to, and what the state is right now
  /// for a subscriber that arrived after it was published.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PlaybackStatusTests {
    /// The criterion this exists for. A transitions-only stream leaves a late
    /// subscriber with nothing until something changes, which for an idle or
    /// settled player may be never.
    @Test
    func `A late subscriber is told the current status immediately`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))

      var iterator = player.playbackStatus.makeAsyncIterator()
      let first = await iterator.next()

      #expect(first?.generation == player.generation)
      #expect(first?.state == player.state)
    }

    /// `load(_:)` starts a new session, and the status has to say so even
    /// though the state may not have moved at all.
    @Test
    func `Loading new media advances the generation on the stream`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let before = player.generation

      try player.load(Media(url: TestMedia.twosecURL))

      var iterator = player.playbackStatus.makeAsyncIterator()
      let latest = await iterator.next()

      #expect(player.generation > before)
      #expect(latest?.generation == player.generation)
    }

    /// The point of pairing them. Two sessions can sit in the same state, and
    /// on `stateTransitions` those are indistinguishable.
    @Test
    func `The same state in two sessions carries different generations`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      var iterator = player.playbackStatus.makeAsyncIterator()
      let first = await iterator.next()

      try player.load(Media(url: TestMedia.twosecURL))
      let second = await iterator.next()

      #expect(first?.state == second?.state)
      #expect(first?.generation != second?.generation)
    }

    /// `stateTransitions` must keep its no-replay behaviour. `recast(to:)`
    /// captures it before calling `play()` and awaits the *next* `.playing`; a
    /// replayed one from the outgoing session would let it report success
    /// before the replacement session ever started.
    @Test
    func `stateTransitions still does not replay`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.publishPlaybackState(.paused)

      let transitions = player.stateTransitions
      player.stateTransitionBridge.terminate()

      var received: [PlayerState] = []
      for await state in transitions {
        received.append(state)
      }

      #expect(received.isEmpty, "stateTransitions replayed a state; recast(to:) would act on the outgoing session")
    }

    /// Generations are identity, not arithmetic. Ordering is the only thing a
    /// consumer should read into them, and it has to survive being compared
    /// across sessions.
    @Test
    func `Generations order by when their sessions began`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let first = player.generation
      try player.load(Media(url: TestMedia.twosecURL))
      let second = player.generation

      #expect(first < second)
      #expect(first != second)
      #expect(first == first)
    }

    /// A terminated player must not strand a subscriber waiting on a replay
    /// that will never come.
    @Test
    func `The status stream finishes when the player tears down`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))

      let stream = player.playbackStatus
      player.playbackStatusBridge.terminate()

      var count = 0
      for await _ in stream {
        count += 1
      }

      #expect(count <= 1, "the stream should finish rather than hang after termination")
    }
  }
}
