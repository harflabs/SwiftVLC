@testable import SwiftVLC
import Testing

@Suite(
  "EventBridge", .tags(.integration, .mainActor, .async), .serialized,
  .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)")
)
@MainActor
struct EventBridgeTests {
  @Test("Independent streams")
  func independentStreams() async throws {
    let player = try Player()
    let stream1 = player.events
    let stream2 = player.events
    // Both streams should be independent
    let t1 = Task { for await _ in stream1 {
      break
    } }
    let t2 = Task { for await _ in stream2 {
      break
    } }
    t1.cancel()
    t2.cancel()
    await t1.value
    await t2.value
  }

  @Test("Events arrive on playback")
  func eventsArriveOnPlayback() async throws {
    let player = try Player()
    let stream = player.events
    let media = try Media(url: TestMedia.testMP4URL)

    var receivedEvent = false
    let task = Task {
      for await _ in stream {
        receivedEvent = true
        break
      }
    }

    try player.play(media)
    try await Task.sleep(for: .milliseconds(500))
    task.cancel()
    await task.value
    player.stop()
    #expect(receivedEvent)
  }

  @Test("Multiple consumers receive same events")
  func multipleConsumersSameEvents() async throws {
    let player = try Player()
    let stream1 = player.events
    let stream2 = player.events

    var count1 = 0
    var count2 = 0

    let t1 = Task {
      for await _ in stream1 {
        count1 += 1
        if count1 >= 2 { break }
      }
    }
    let t2 = Task {
      for await _ in stream2 {
        count2 += 1
        if count2 >= 2 { break }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    try await Task.sleep(for: .milliseconds(500))

    t1.cancel()
    t2.cancel()
    await t1.value
    await t2.value
    player.stop()

    // Both consumers should have received events
    #expect(count1 > 0)
    #expect(count2 > 0)
  }

  @Test("Terminated stream cleanup")
  func terminatedStreamCleanup() async throws {
    let player = try Player()
    let stream = player.events
    let task = Task {
      for await _ in stream {
        break
      }
    }
    task.cancel()
    await task.value
    // Creating another stream should still work
    let stream2 = player.events
    let task2 = Task {
      for await _ in stream2 {
        break
      }
    }
    task2.cancel()
    await task2.value
  }

  @Test("Invalidate finishes streams")
  func invalidateFinishesStreams() async throws {
    // Verify player can be created and destroyed safely.
    // Scope the player so it deinits on the main actor.
    let stream: AsyncStream<PlayerEvent>
    do {
      let player = try Player()
      stream = player.events
    }
    // Player is now deinitialized — stream should finish
    let task = Task {
      for await _ in stream {}
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await task.value
  }

  @Test("State transitions received during playback")
  func stateTransitionsDuringPlayback() async throws {
    let player = try Player()
    let stream = player.events

    var receivedStates: [PlayerState] = []
    let task = Task {
      for await event in stream {
        if case .stateChanged(let state) = event {
          receivedStates.append(state)
          if state == .playing || state == .stopped || receivedStates.count >= 5 {
            break
          }
        }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    try await Task.sleep(for: .milliseconds(800))
    player.stop()
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await task.value

    // Should have received at least opening → playing states
    #expect(!receivedStates.isEmpty)
  }

  @Test("Time and position events during playback")
  func timeAndPositionEventsDuringPlayback() async throws {
    let player = try Player()
    let stream = player.events

    var receivedTime = false
    var receivedPosition = false
    let task = Task {
      for await event in stream {
        switch event {
        case .timeChanged:
          receivedTime = true
        case .positionChanged:
          receivedPosition = true
        default:
          break
        }
        if receivedTime && receivedPosition { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(800))
    task.cancel()
    await task.value
    player.stop()

    #expect(receivedTime)
    #expect(receivedPosition)
  }

  @Test("Length changed event during playback")
  func lengthChangedDuringPlayback() async throws {
    let player = try Player()
    let stream = player.events

    var receivedLength = false
    let task = Task {
      for await event in stream {
        if case .lengthChanged = event {
          receivedLength = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(800))
    task.cancel()
    await task.value
    player.stop()

    #expect(receivedLength)
  }

  @Test("Seekable and pausable events during playback")
  func seekablePausableEventsDuringPlayback() async throws {
    let player = try Player()
    let stream = player.events

    var receivedSeekable = false
    var receivedPausable = false
    let task = Task {
      for await event in stream {
        switch event {
        case .seekableChanged:
          receivedSeekable = true
        case .pausableChanged:
          receivedPausable = true
        default:
          break
        }
        if receivedSeekable && receivedPausable { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(800))
    task.cancel()
    await task.value
    player.stop()

    // Local files should trigger both
    #expect(receivedSeekable)
    #expect(receivedPausable)
  }

  @Test("Mute events")
  func muteEvents() async throws {
    let player = try Player()
    let stream = player.events

    var receivedMuted = false
    var receivedUnmuted = false
    let task = Task {
      for await event in stream {
        switch event {
        case .muted:
          receivedMuted = true
        case .unmuted:
          receivedUnmuted = true
        default:
          break
        }
        if receivedMuted && receivedUnmuted { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(300))
    player.isMuted = true
    try await Task.sleep(for: .milliseconds(100))
    player.isMuted = false
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await task.value
    player.stop()

    #expect(receivedMuted)
    #expect(receivedUnmuted)
  }

  @Test("Volume changed event")
  func volumeChangedEvent() async throws {
    let player = try Player()
    let stream = player.events

    var receivedVolumeChanged = false
    let task = Task {
      for await event in stream {
        if case .volumeChanged = event {
          receivedVolumeChanged = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(300))
    player.volume = 0.5
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await task.value
    player.stop()

    #expect(receivedVolumeChanged)
  }

  @Test("Stopped event resets player state")
  func stoppedEventResetsState() async throws {
    let player = try Player()
    let stream = player.events

    var receivedStopped = false
    let task = Task {
      for await event in stream {
        if case .stateChanged(.stopped) = event {
          receivedStopped = true
          break
        }
        if case .stateChanged(.stopping) = event {
          // also expected
        }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    try await Task.sleep(for: .milliseconds(500))
    player.stop()
    try await Task.sleep(for: .milliseconds(500))
    task.cancel()
    await task.value

    #expect(receivedStopped)
  }

  @Test("Tracks changed event after load")
  func tracksChangedAfterLoad() async throws {
    let player = try Player()
    let stream = player.events

    var receivedTracksChanged = false
    var receivedMediaChanged = false
    let task = Task {
      for await event in stream {
        switch event {
        case .tracksChanged:
          receivedTracksChanged = true
        case .mediaChanged:
          receivedMediaChanged = true
        default:
          break
        }
        if receivedTracksChanged || receivedMediaChanged { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(800))
    task.cancel()
    await task.value
    player.stop()

    // At least one of tracksChanged or mediaChanged should fire
    #expect(receivedTracksChanged || receivedMediaChanged)
  }

  @Test("Buffering progress event during playback")
  func bufferingProgressDuringPlayback() async throws {
    let player = try Player()
    let stream = player.events

    var receivedBuffering = false
    let task = Task {
      for await event in stream {
        if case .bufferingProgress = event {
          receivedBuffering = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    try await Task.sleep(for: .milliseconds(800))
    task.cancel()
    await task.value
    player.stop()

    // Buffering events typically fire during media load
    #expect(receivedBuffering)
  }
}
