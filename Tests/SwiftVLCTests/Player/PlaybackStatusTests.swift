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

      let stream = player.playbackStatus
      player.playbackStatusBridge.terminate()

      var received: [PlaybackStatus] = []
      for await status in stream {
        received.append(status)
      }

      #expect(received.last?.generation == player.generation)
      #expect(received.last?.state == player.state)
    }

    /// The gap the first version had. Every other test here loads media first,
    /// so all of them missed a player that has never published anything: the
    /// broadcaster had no latest element, the replay yielded nothing, and a
    /// subscriber to an idle player would wait indefinitely for a stream
    /// documented as opening with the current status.
    ///
    /// Drained after terminating rather than awaited on an iterator: if the
    /// replay is missing there is nothing to receive, and awaiting would hang
    /// instead of failing. A test that hangs on regression reports nothing
    /// useful.
    @Test
    func `A subscriber to a fresh player receives its idle status`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let stream = player.playbackStatus
      player.playbackStatusBridge.terminate()

      var received: [PlaybackStatus] = []
      for await status in stream {
        received.append(status)
      }

      #expect(received.first?.state == .idle)
      #expect(received.first?.generation == player.generation)
    }

    /// `load(_:)` starts a new session, and the status has to say so even
    /// though the state may not have moved at all.
    @Test
    func `Loading new media advances the generation on the stream`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let before = player.generation

      try player.load(Media(url: TestMedia.twosecURL))

      let stream = player.playbackStatus
      player.playbackStatusBridge.terminate()

      var received: [PlaybackStatus] = []
      for await status in stream {
        received.append(status)
      }

      #expect(player.generation > before)
      #expect(received.last?.generation == player.generation)
    }

    /// The point of pairing them. Two sessions can sit in the same state, and
    /// on `stateTransitions` those are indistinguishable.
    @Test
    func `The same state in two sessions carries different generations`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let stream = player.playbackStatus
      try player.load(Media(url: TestMedia.twosecURL))
      player.playbackStatusBridge.terminate()

      var received: [PlaybackStatus] = []
      for await status in stream {
        received.append(status)
      }

      let first = received.first
      let second = received.last
      #expect(received.count >= 2)
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
