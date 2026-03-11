@testable import SwiftVLC
import Testing

@Suite(
  .tags(.integration, .mainActor, .async),
  .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)")
)
@MainActor
struct EventBridgeTests {
  @Test(.timeLimit(.minutes(1)))
  func `Independent streams`() {
    let player = Player()
    let stream1 = player.events
    let stream2 = player.events
    let t1 = Task { for await _ in stream1 {
      break
    } }
    let t2 = Task { for await _ in stream2 {
      break
    } }
    t1.cancel()
    t2.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Events arrive on playback`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedEvent = false
    let task = Task.detached { @Sendable in
      for await _ in stream {
        receivedEvent = true
        break
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    guard try await poll(until: { receivedEvent }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()
    #expect(receivedEvent)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Multiple consumers receive same events`() async throws {
    let player = Player()
    let stream1 = player.events
    let stream2 = player.events

    nonisolated(unsafe) var count1 = 0
    nonisolated(unsafe) var count2 = 0

    let t1 = Task.detached { @Sendable in
      for await _ in stream1 {
        count1 += 1
        if count1 >= 2 { break }
      }
    }
    let t2 = Task.detached { @Sendable in
      for await _ in stream2 {
        count2 += 1
        if count2 >= 2 { break }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    guard try await poll(until: { count1 > 0 && count2 > 0 }) else {
      t1.cancel()
      t2.cancel()
      player.stop()
      return
    }

    t1.cancel()
    t2.cancel()
    player.stop()

    #expect(count1 > 0)
    #expect(count2 > 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Terminated stream cleanup`() {
    let player = Player()
    let stream = player.events
    let task = Task { for await _ in stream {
      break
    } }
    task.cancel()
    let stream2 = player.events
    let task2 = Task { for await _ in stream2 {
      break
    } }
    task2.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Invalidate finishes streams`() async throws {
    let stream: AsyncStream<PlayerEvent>
    do {
      let player = Player()
      stream = player.events
    }
    let task = Task { for await _ in stream {} }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `State transitions received during playback`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedStates: [PlayerState] = []
    let task = Task.detached { @Sendable in
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
    guard try await poll(until: { !receivedStates.isEmpty }) else {
      task.cancel()
      player.stop()
      return
    }
    player.stop()
    guard try await poll(until: { receivedStates.contains(where: { $0 == .stopped || $0 == .stopping }) }) else {
      task.cancel()
      return
    }
    task.cancel()

    #expect(!receivedStates.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Time and position events during playback`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedTime = false
    nonisolated(unsafe) var receivedPosition = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .timeChanged: receivedTime = true
        case .positionChanged: receivedPosition = true
        default: break
        }
        if receivedTime && receivedPosition { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedTime && receivedPosition }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedTime)
    #expect(receivedPosition)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Length changed event during playback`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedLength = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .lengthChanged = event {
          receivedLength = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedLength }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedLength)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Seekable and pausable events during playback`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedSeekable = false
    nonisolated(unsafe) var receivedPausable = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .seekableChanged: receivedSeekable = true
        case .pausableChanged: receivedPausable = true
        default: break
        }
        if receivedSeekable && receivedPausable { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedSeekable && receivedPausable }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedSeekable)
    #expect(receivedPausable)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Mute events`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedMuted = false
    nonisolated(unsafe) var receivedUnmuted = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .muted: receivedMuted = true
        case .unmuted: receivedUnmuted = true
        default: break
        }
        if receivedMuted && receivedUnmuted { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else {
      task.cancel()
      player.stop()
      return
    }
    player.isMuted = true
    try await Task.sleep(for: .milliseconds(50))
    player.isMuted = false
    guard try await poll(until: { receivedMuted && receivedUnmuted }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedMuted)
    #expect(receivedUnmuted)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Volume changed event`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedVolumeChanged = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .volumeChanged = event {
          receivedVolumeChanged = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else {
      task.cancel()
      player.stop()
      return
    }
    player.volume = 0.5
    guard try await poll(until: { receivedVolumeChanged }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedVolumeChanged)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Stopped event resets player state`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedStopped = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .stateChanged(.stopped) = event {
          receivedStopped = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    guard try await poll(until: { player.state == .playing }) else {
      task.cancel()
      player.stop()
      return
    }
    player.stop()
    guard try await poll(until: { receivedStopped }) else {
      task.cancel()
      return
    }
    task.cancel()

    #expect(receivedStopped)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Tracks changed event after load`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedTracksChanged = false
    nonisolated(unsafe) var receivedMediaChanged = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .tracksChanged: receivedTracksChanged = true
        case .mediaChanged: receivedMediaChanged = true
        default: break
        }
        if receivedTracksChanged || receivedMediaChanged { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedTracksChanged || receivedMediaChanged }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedTracksChanged || receivedMediaChanged)
  }

  @Test(.timeLimit(.minutes(1)))
  func `Buffering progress event during playback`() async throws {
    let player = Player()
    let stream = player.events

    nonisolated(unsafe) var receivedBuffering = false
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .bufferingProgress = event {
          receivedBuffering = true
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedBuffering }) else {
      task.cancel()
      player.stop()
      return
    }
    task.cancel()
    player.stop()

    #expect(receivedBuffering)
  }
}
