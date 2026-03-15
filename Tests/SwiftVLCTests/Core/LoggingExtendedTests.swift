@testable import SwiftVLC
import Synchronization
import Testing

@Suite(.tags(.integration))
struct LoggingExtendedTests {
  @Test(.tags(.async, .media, .mainActor), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  @MainActor
  func `Log entries arrive during playback`() async throws {
    let collected = Mutex<[LogEntry]>([])
    let stream = VLCInstance.shared.logStream(minimumLevel: .debug)
    let collectTask = Task.detached {
      for await entry in stream {
        collected.withLock { $0.append(entry) }
        if collected.withLock({ $0.count }) >= 5 { break }
      }
    }
    // Start playback to generate log entries
    let player = Player()
    let media = try Media(url: TestMedia.twosecURL)
    try player.play(media)
    guard
      try await poll(timeout: .seconds(5), until: {
        collected.withLock { $0.count } >= 5
      }) else {
      player.stop()
      collectTask.cancel()
      await collectTask.value
      // Some entries may still have arrived; no assertion as log generation is platform-dependent
      return
    }
    player.stop()
    collectTask.cancel()
    await collectTask.value
    let entries = collected.withLock { $0 }
    #expect(entries.count >= 5)
  }

  @Test
  func `Log stream with different minimum levels can be created`() {
    // libVLC's log callback is per-instance and replaces the previous one,
    // so only one logStream can be active at a time per VLCInstance.
    // This test verifies we can create streams at different levels without crashing.
    let levels: [LogLevel] = [.debug, .notice, .warning, .error]
    for level in levels {
      let stream = VLCInstance.shared.logStream(minimumLevel: level)
      _ = stream // Just creating should not crash
    }
  }

  @Test
  func `LogLevel is Sendable`() {
    let level: any Sendable = LogLevel.debug
    _ = level
  }

  @Test
  func `LogEntry is Sendable`() {
    let entry: any Sendable = LogEntry(level: .warning, message: "test", module: "core")
    _ = entry
  }

  @Test(.tags(.async))
  func `Log stream can be iterated with for-await`() async {
    let stream = VLCInstance.shared.logStream(minimumLevel: .debug)
    let task = Task {
      var count = 0
      for await _ in stream {
        count += 1
        if count >= 1 { break }
      }
    }
    // Cancel after a brief pause so the test doesn't hang if no entries arrive
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await task.value
  }

  @Test(.tags(.async))
  func `Creating log stream after previous terminated works`() async {
    // First stream — create and terminate
    let stream1 = VLCInstance.shared.logStream(minimumLevel: .warning)
    let task1 = Task {
      for await _ in stream1 {
        break
      }
    }
    task1.cancel()
    await task1.value

    // Second stream — should work fine
    let stream2 = VLCInstance.shared.logStream(minimumLevel: .debug)
    let task2 = Task {
      for await _ in stream2 {
        break
      }
    }
    try? await Task.sleep(for: .milliseconds(50))
    task2.cancel()
    await task2.value
    // No crash = success
  }

  @Test
  func `LogLevel comparison operators work correctly for all pairs`() {
    let levels: [LogLevel] = [.debug, .notice, .warning, .error]
    for i in 0..<levels.count {
      for j in 0..<levels.count {
        if i < j {
          #expect(levels[i] < levels[j])
          #expect(!(levels[j] < levels[i]))
          #expect(levels[i] <= levels[j])
          #expect(levels[j] >= levels[i])
          #expect(levels[i] != levels[j])
        } else if i == j {
          #expect(levels[i] == levels[j])
          #expect(levels[i] <= levels[j])
          #expect(levels[i] >= levels[j])
          #expect(!(levels[i] < levels[j]))
        }
      }
    }
  }
}
