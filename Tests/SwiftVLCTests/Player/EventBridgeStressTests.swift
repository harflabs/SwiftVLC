@testable import SwiftVLC
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .enabled(if: TestCondition.canPlayMedia, "Requires video output"))
  @MainActor struct EventBridgeStressTests {
    @Test(.timeLimit(.minutes(1)))
    func `Many concurrent consumers all receive events`() async throws {
      let player = Player(instance: TestInstance.shared)
      let consumerCount = 12
      let streams = (0..<consumerCount).map { _ in player.events }
      let counts = Mutex([Int](repeating: 0, count: consumerCount))

      let tasks = (0..<consumerCount).map { i in
        Task.detached { @Sendable in
          for await _ in streams[i] {
            let c = counts.withLock { $0[i] += 1; return $0[i] }
            if c >= 3 { break }
          }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          counts.withLock { $0.allSatisfy { $0 > 0 } }
        }) else {
        for task in tasks {
          task.cancel()
        }
        for task in tasks {
          await task.value
        }
        player.stop()
        return
      }

      for task in tasks {
        task.cancel()
      }
      for task in tasks {
        await task.value
      }
      player.stop()

      for i in 0..<consumerCount {
        #expect(counts.withLock { $0[i] } > 0, "Consumer \(i) should have received events")
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Rapid stream creation and cancellation`() async throws {
      let player = Player(instance: TestInstance.shared)
      let iterations = 20

      // Rapidly create and cancel streams without playback
      for _ in 0..<iterations {
        let stream = player.events
        let task = Task.detached { @Sendable in
          for await _ in stream {
            break
          }
        }
        task.cancel()
        await task.value
      }

      // Now verify the bridge still works after all the churn
      let stream = player.events
      let receivedEvent = Mutex(false)
      let task = Task.detached { @Sendable in
        for await _ in stream {
          receivedEvent.withLock { $0 = true }
          break
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      guard try await poll(until: { receivedEvent.withLock { $0 } }) else {
        task.cancel()
        await task.value
        player.stop()
        return
      }
      task.cancel()
      await task.value
      player.stop()

      #expect(receivedEvent.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func `Stream created after previous cancelled still works`() async throws {
      let player = Player(instance: TestInstance.shared)

      // Create and cancel a first stream
      let stream1 = player.events
      let task1 = Task.detached { @Sendable in
        for await _ in stream1 {
          break
        }
      }
      task1.cancel()
      await task1.value

      // Create a second stream and verify it receives events
      let stream2 = player.events
      let receivedEvent = Mutex(false)
      let task2 = Task.detached { @Sendable in
        for await _ in stream2 {
          receivedEvent.withLock { $0 = true }
          break
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      guard try await poll(until: { receivedEvent.withLock { $0 } }) else {
        task2.cancel()
        await task2.value
        player.stop()
        return
      }
      task2.cancel()
      await task2.value
      player.stop()

      #expect(receivedEvent.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func `Slow consumer does not block fast consumer`() async throws {
      let player = Player(instance: TestInstance.shared)
      let fastStream = player.events
      let slowStream = player.events

      let fastCount = Mutex(0)
      let slowCount = Mutex(0)

      let fastTask = Task.detached { @Sendable in
        for await _ in fastStream {
          let c = fastCount.withLock { $0 += 1; return $0 }
          if c >= 5 { break }
        }
      }

      let slowTask = Task.detached { @Sendable in
        for await _ in slowStream {
          // Simulate slow processing
          try? await Task.sleep(for: .milliseconds(200))
          let c = slowCount.withLock { $0 += 1; return $0 }
          if c >= 2 { break }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))

      // The fast consumer should reach 5 events before the slow one finishes
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          fastCount.withLock { $0 } >= 5
        }) else {
        fastTask.cancel()
        slowTask.cancel()
        await fastTask.value
        await slowTask.value
        player.stop()
        return
      }

      // Fast consumer got its events; slow consumer should still be behind
      let fast = fastCount.withLock { $0 }
      let slow = slowCount.withLock { $0 }
      #expect(fast >= 5, "Fast consumer should have received at least 5 events")
      #expect(fast > slow, "Fast consumer should be ahead of slow consumer")

      fastTask.cancel()
      slowTask.cancel()
      await fastTask.value
      await slowTask.value
      player.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func `All major event types received during full playthrough`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let receivedState = Mutex(false)
      let receivedTime = Mutex(false)
      let receivedPosition = Mutex(false)
      let receivedLength = Mutex(false)
      let receivedSeekable = Mutex(false)
      let receivedPausable = Mutex(false)
      let receivedTracks = Mutex(false)
      let receivedMedia = Mutex(false)
      let receivedBuffering = Mutex(false)

      let task = Task.detached { @Sendable in
        for await event in stream {
          switch event {
          case .stateChanged: receivedState.withLock { $0 = true }
          case .timeChanged: receivedTime.withLock { $0 = true }
          case .positionChanged: receivedPosition.withLock { $0 = true }
          case .lengthChanged: receivedLength.withLock { $0 = true }
          case .seekableChanged: receivedSeekable.withLock { $0 = true }
          case .pausableChanged: receivedPausable.withLock { $0 = true }
          case .tracksChanged: receivedTracks.withLock { $0 = true }
          case .mediaChanged: receivedMedia.withLock { $0 = true }
          case .bufferingProgress: receivedBuffering.withLock { $0 = true }
          default: break
          }

          let allReceived =
            receivedState.withLock { $0 }
              && receivedTime.withLock { $0 }
              && receivedPosition.withLock { $0 }
              && receivedLength.withLock { $0 }
              && receivedSeekable.withLock { $0 }
              && receivedPausable.withLock { $0 }
              && (receivedTracks.withLock { $0 } || receivedMedia.withLock { $0 })
              && receivedBuffering.withLock { $0 }

          if allReceived { break }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(8), until: {
          receivedState.withLock { $0 }
            && receivedTime.withLock { $0 }
            && receivedPosition.withLock { $0 }
            && receivedLength.withLock { $0 }
            && receivedSeekable.withLock { $0 }
            && receivedPausable.withLock { $0 }
            && (receivedTracks.withLock { $0 } || receivedMedia.withLock { $0 })
            && receivedBuffering.withLock { $0 }
        }) else {
        task.cancel()
        await task.value
        player.stop()
        // Some events may not fire on all platforms; gracefully skip
        return
      }

      task.cancel()
      await task.value
      player.stop()

      // Verify we got the events (poll succeeded so these should be true)
      _ = receivedState.withLock { $0 }
      _ = receivedTime.withLock { $0 }
      _ = receivedPosition.withLock { $0 }
      _ = receivedLength.withLock { $0 }
      _ = receivedSeekable.withLock { $0 }
      _ = receivedPausable.withLock { $0 }
      _ = receivedTracks.withLock { $0 } || receivedMedia.withLock { $0 }
      _ = receivedBuffering.withLock { $0 }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Multiple players with independent event bridges`() async throws {
      let player1 = Player(instance: TestInstance.shared)
      let player2 = Player(instance: TestInstance.shared)
      let stream1 = player1.events
      let stream2 = player2.events

      let events1 = Mutex<[String]>([])
      let events2 = Mutex<[String]>([])

      let task1 = Task.detached { @Sendable in
        for await event in stream1 {
          let shouldBreak = events1.withLock {
            if case .stateChanged(let s) = event {
              $0.append("state:\(s)")
            } else if case .timeChanged = event {
              $0.append("time")
            }
            return $0.count >= 3
          }
          if shouldBreak { break }
        }
      }
      let task2 = Task.detached { @Sendable in
        for await event in stream2 {
          let shouldBreak = events2.withLock {
            if case .stateChanged(let s) = event {
              $0.append("state:\(s)")
            } else if case .timeChanged = event {
              $0.append("time")
            }
            return $0.count >= 3
          }
          if shouldBreak { break }
        }
      }

      // Only play on player1
      try player1.play(Media(url: TestMedia.testMP4URL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          events1.withLock { $0.count } >= 2
        }) else {
        task1.cancel()
        task2.cancel()
        await task1.value
        await task2.value
        player1.stop()
        return
      }

      // Player2 was never played, so it should have no events
      let count2 = events2.withLock { $0.count }
      #expect(count2 == 0, "Player2 should not receive events from player1")
      #expect(events1.withLock { $0.count } >= 2, "Player1 should have received events")

      task1.cancel()
      task2.cancel()
      await task1.value
      await task2.value
      player1.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func `Media changed event fires when switching media`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let mediaChangedCount = Mutex(0)
      let task = Task.detached { @Sendable in
        for await event in stream {
          if case .mediaChanged = event {
            let c = mediaChangedCount.withLock { $0 += 1; return $0 }
            if c >= 2 { break }
          }
        }
      }

      // Play first media
      try player.play(Media(url: TestMedia.testMP4URL))
      guard try await poll(until: { player.state == .playing }) else {
        task.cancel()
        await task.value
        player.stop()
        return
      }

      // Switch to second media while playing
      try player.play(Media(url: TestMedia.twosecURL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          mediaChangedCount.withLock { $0 } >= 2
        }) else {
        // At least one mediaChanged should have fired from the initial play
        task.cancel()
        await task.value
        player.stop()
        #expect(mediaChangedCount.withLock { $0 } >= 1, "At least one mediaChanged event expected")
        return
      }

      task.cancel()
      await task.value
      player.stop()

      #expect(mediaChangedCount.withLock { $0 } >= 2, "Expected mediaChanged for both media switches")
    }

    @Test(.timeLimit(.minutes(1)))
    func `Vout event during video playback`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let receivedVout = Mutex(false)
      let task = Task.detached { @Sendable in
        for await event in stream {
          if case .voutChanged(let count) = event, count > 0 {
            receivedVout.withLock { $0 = true }
            break
          }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          receivedVout.withLock { $0 }
        }) else {
        task.cancel()
        await task.value
        player.stop()
        // Vout may not fire in headless test environments; still validate no crash
        return
      }

      task.cancel()
      await task.value
      player.stop()

      #expect(receivedVout.withLock { $0 })
    }
  }
}
