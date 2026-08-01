@testable import SwiftVLC
import CLibVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PlaybackTerminalOutcomeTests {
    @Test
    func `Replacement freezes the outgoing generation and final timeline`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = try Media(url: TestMedia.twosecURL)
      player.load(first)
      let generation = player.generation
      let nativeGeneration = player.nativeEventGeneration
      let outcome = firstOutcome(from: player.terminalOutcomes)

      let native = player.eventBridge.currentNativeHandleGeneration
      // Duration can be learned by the wrapper's native poll without a
      // LengthChanged callback, and paused seeks may not emit clock events.
      // Both synchronous facts still belong in the frozen outcome.
      player._setStateForTesting(duration: .seconds(60))
      player.commitSeekTarget(
        milliseconds: 15000,
        revision: player.eventBridge.advanceTimelineRevision()
      )
      player.eventBridge._broadcastForTesting(.bufferingProgress(0.75), nativeHandleGeneration: native)
      player.eventBridge._broadcastForTesting(.voutChanged(2), nativeHandleGeneration: native)

      try player.load(Media(url: TestMedia.silenceURL))

      let value = try #require(await outcome.value)
      #expect(value.generation == generation)
      #expect(value.nativeGeneration == nativeGeneration)
      #expect(value.cause == .replacement)
      #expect(value.finalTimeline.time == .seconds(15))
      #expect(value.finalTimeline.duration == .seconds(60))
      #expect(value.finalTimeline.position == 0.25)
      #expect(value.finalTimeline.bufferFill == 0.75)
      #expect(value.finalTimeline.activeVideoOutputs == 2)
    }

    @Test
    func `An explicit stop intent outranks a following media replacement`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let outgoing = player.sessionGeneration
      let outcome = firstOutcome(from: player.terminalOutcomes)

      player.eventBridge.markRequestedStop(playbackGeneration: outgoing)
      try player.load(Media(url: TestMedia.silenceURL))

      let value = try #require(await outcome.value)
      #expect(value.generation == PlaybackGeneration(outgoing))
      #expect(value.cause == .requestedStop)
    }

    @Test
    func `Authoritative EOF emits once before the stopped reset`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)
      let expectedGeneration = player.generation
      let stream = player.terminalOutcomes
      let outcomes = collect(stream, for: .milliseconds(100))

      let native = player.eventBridge.currentNativeHandleGeneration
      player.eventBridge._broadcastForTesting(.timeChanged(.seconds(2)), nativeHandleGeneration: native)
      var stopping = libvlc_event_t()
      stopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      stopping.u.media_player_media_stopping.media = media.pointer
      stopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      player.eventBridge._emitNativeEventForTesting(stopping)

      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      player.eventBridge._emitNativeEventForTesting(stopped)

      let values = await outcomes.value
      #expect(values.count == 1)
      let value = try #require(values.first)
      #expect(value.generation == expectedGeneration)
      #expect(value.cause == .naturalEnd)
      #expect(value.finalTimeline.time == .seconds(2))
    }

    @Test
    func `Unattributed stop reports unknown and never claims natural end`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let outcome = firstOutcome(from: player.terminalOutcomes)

      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      player.eventBridge._emitNativeEventForTesting(stopped)

      let value = try #require(await outcome.value)
      #expect(value.cause == .unknownNativeStop)
      await Task.yield()
      #expect(!player.didReachEnd)
    }

    @Test
    func `A stale terminal transition cannot reset its successor`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let outgoing = player.sessionGeneration
      try player.load(Media(url: TestMedia.silenceURL))
      player._setStateForTesting(
        state: .playing,
        currentTime: .seconds(9),
        duration: .seconds(30),
        position: 0.3
      )

      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
          playbackGeneration: outgoing,
          event: .stateChanged(.stopped)
        )
      )

      #expect(player.state == .playing)
      #expect(player.currentTime == .seconds(9))
      #expect(player.position == 0.3)
    }

    @Test
    func `Reloading the same media cannot attribute the retired stop to its successor`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)
      let firstGeneration = player.generation
      let sharedPointer = try #require(player.currentMedia?.pointer)
      let outcomes = collect(player.terminalOutcomes, for: .milliseconds(100))

      player.load(Media(retaining: sharedPointer))
      let secondGeneration = player.generation

      var retiredStopping = libvlc_event_t()
      retiredStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      retiredStopping.u.media_player_media_stopping.media = sharedPointer
      retiredStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_user
      player.eventBridge._emitNativeEventForTesting(retiredStopping)

      player.eventBridge._broadcastForTesting(
        .stateChanged(.opening),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration
      )

      var currentStopping = libvlc_event_t()
      currentStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      currentStopping.u.media_player_media_stopping.media = sharedPointer
      currentStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      player.eventBridge._emitNativeEventForTesting(currentStopping)

      let values = await outcomes.value
      #expect(values.map(\.generation) == [firstGeneration, secondGeneration])
      #expect(values.map(\.cause) == [.replacement, .naturalEnd])
    }

    private func firstOutcome(
      from stream: AsyncStream<PlaybackTerminalOutcome>
    ) -> Task<PlaybackTerminalOutcome?, Never> {
      Task.detached {
        await withTaskGroup(of: PlaybackTerminalOutcome?.self) { group in
          group.addTask { await stream.first(where: { _ in true }) }
          group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
          }
          let value = await group.next() ?? nil
          group.cancelAll()
          return value
        }
      }
    }

    private func collect(
      _ stream: AsyncStream<PlaybackTerminalOutcome>,
      for duration: Duration
    ) -> Task<[PlaybackTerminalOutcome], Never> {
      Task.detached {
        let collector = Task { () -> [PlaybackTerminalOutcome] in
          var values: [PlaybackTerminalOutcome] = []
          for await value in stream {
            values.append(value)
          }
          return values
        }
        try? await Task.sleep(for: duration)
        collector.cancel()
        return await collector.value
      }
    }
  }
}
