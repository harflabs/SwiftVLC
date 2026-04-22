@testable import SwiftVLC
import Synchronization
import Testing

@Suite(
  .tags(.integration, .mainActor, .async),
  .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)")
)
@MainActor
struct EventBridgeTests {
  @Test(.timeLimit(.minutes(1)))
  func `Independent streams`() {
    let player = Player(instance: TestInstance.shared)
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
    let player = Player(instance: TestInstance.shared)
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
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Multiple consumers receive same events`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream1 = player.events
    let stream2 = player.events

    let count1 = Mutex(0)
    let count2 = Mutex(0)

    let t1 = Task.detached { @Sendable in
      for await _ in stream1 {
        let c = count1.withLock { $0 += 1; return $0 }
        if c >= 2 { break }
      }
    }
    let t2 = Task.detached { @Sendable in
      for await _ in stream2 {
        let c = count2.withLock { $0 += 1; return $0 }
        if c >= 2 { break }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    guard try await poll(until: { count1.withLock { $0 } > 0 && count2.withLock { $0 } > 0 }) else {
      player.stop()
      t1.cancel()
      t2.cancel()
      return
    }

    player.stop()
    t1.cancel()
    t2.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Terminated stream cleanup`() {
    let player = Player(instance: TestInstance.shared)
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
      let player = Player(instance: TestInstance.shared)
      stream = player.events
    }
    let task = Task { for await _ in stream {} }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `State transitions received during playback`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedStates = Mutex<[PlayerState]>([])
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .stateChanged(let state) = event {
          let shouldBreak = receivedStates.withLock {
            $0.append(state)
            return state == .playing || state == .stopped || $0.count >= 5
          }
          if shouldBreak { break }
        }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    guard try await poll(until: { receivedStates.withLock { !$0.isEmpty } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    guard
      try await poll(until: {
        receivedStates.withLock { $0.contains(where: { $0 == .stopped || $0 == .stopping }) }
      }) else {
      task.cancel()
      return
    }
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Time and position events during playback`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedTime = Mutex(false)
    let receivedPosition = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .timeChanged: receivedTime.withLock { $0 = true }
        case .positionChanged: receivedPosition.withLock { $0 = true }
        default: break
        }
        if receivedTime.withLock({ $0 }) && receivedPosition.withLock({ $0 }) { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedTime.withLock { $0 } && receivedPosition.withLock { $0 } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Length changed event during playback`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedLength = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .lengthChanged = event {
          receivedLength.withLock { $0 = true }
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedLength.withLock { $0 } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Seekable and pausable events during playback`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedSeekable = Mutex(false)
    let receivedPausable = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .seekableChanged: receivedSeekable.withLock { $0 = true }
        case .pausableChanged: receivedPausable.withLock { $0 = true }
        default: break
        }
        if receivedSeekable.withLock({ $0 }) && receivedPausable.withLock({ $0 }) { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedSeekable.withLock { $0 } && receivedPausable.withLock { $0 } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Mute events`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedMuted = Mutex(false)
    let receivedUnmuted = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .muted: receivedMuted.withLock { $0 = true }
        case .unmuted: receivedUnmuted.withLock { $0 = true }
        default: break
        }
        if receivedMuted.withLock({ $0 }) && receivedUnmuted.withLock({ $0 }) { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else {
      player.stop()
      task.cancel()
      return
    }
    player.isMuted = true
    try await Task.sleep(for: .milliseconds(50))
    player.isMuted = false
    guard try await poll(until: { receivedMuted.withLock { $0 } && receivedUnmuted.withLock { $0 } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Volume changed event`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedVolumeChanged = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .volumeChanged = event {
          receivedVolumeChanged.withLock { $0 = true }
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else {
      player.stop()
      task.cancel()
      return
    }
    player.volume = 0.5
    guard try await poll(until: { receivedVolumeChanged.withLock { $0 } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Stopped event resets player state`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedStopped = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .stateChanged(.stopped) = event {
          receivedStopped.withLock { $0 = true }
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.testMP4URL))
    guard try await poll(until: { player.state == .playing }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    guard try await poll(until: { receivedStopped.withLock { $0 } }) else {
      task.cancel()
      return
    }
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Tracks changed event after load`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedTracksChanged = Mutex(false)
    let receivedMediaChanged = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        switch event {
        case .tracksChanged: receivedTracksChanged.withLock { $0 = true }
        case .mediaChanged: receivedMediaChanged.withLock { $0 = true }
        default: break
        }
        if receivedTracksChanged.withLock({ $0 }) || receivedMediaChanged.withLock({ $0 }) { break }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard
      try await poll(until: {
        receivedTracksChanged.withLock { $0 } || receivedMediaChanged.withLock { $0 }
      }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }

  @Test(.timeLimit(.minutes(1)))
  func `Buffering progress event during playback`() async throws {
    let player = Player(instance: TestInstance.shared)
    let stream = player.events

    let receivedBuffering = Mutex(false)
    let task = Task.detached { @Sendable in
      for await event in stream {
        if case .bufferingProgress = event {
          receivedBuffering.withLock { $0 = true }
          break
        }
      }
    }

    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { receivedBuffering.withLock { $0 } }) else {
      player.stop()
      task.cancel()
      return
    }
    player.stop()
    task.cancel()
  }
}
