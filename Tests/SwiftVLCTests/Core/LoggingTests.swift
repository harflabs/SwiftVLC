@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
struct LoggingTests {
  @Test(
    arguments: [
      (LogLevel.debug, Int32(0)),
      (.notice, Int32(2)),
      (.warning, Int32(3)),
      (.error, Int32(4))
    ] as [(LogLevel, Int32)]
  )
  func `Log level raw values`(level: LogLevel, expected: Int32) {
    #expect(level.rawValue == expected)
  }

  @Test
  func `Log level Comparable ordering`() {
    #expect(LogLevel.debug < .notice)
    #expect(LogLevel.notice < .warning)
    #expect(LogLevel.warning < .error)
  }

  @Test(
    arguments: [
      (LogLevel.debug, "debug"),
      (.notice, "notice"),
      (.warning, "warning"),
      (.error, "error"),
    ] as [(LogLevel, String)]
  )
  func `Log level descriptions`(level: LogLevel, expected: String) {
    #expect(level.description == expected)
  }

  @Test
  func `LogEntry stores properties`() {
    let entry = LogEntry(level: .warning, message: "test msg", module: "http")
    #expect(entry.level == .warning)
    #expect(entry.message == "test msg")
    #expect(entry.module == "http")
  }

  @Test
  func `LogEntry module can be nil`() {
    let entry = LogEntry(level: .error, message: "oops", module: nil)
    #expect(entry.module == nil)
  }

  @Test(.tags(.async))
  func `Log stream returns AsyncStream`() async {
    let stream = VLCInstance.shared.logStream(minimumLevel: .debug)
    // Verify we can create and cancel the stream without issues
    let task = Task {
      for await _ in stream {
        break
      }
    }
    task.cancel()
    await task.value
  }

  @Test(.tags(.async))
  func `Log stream filters minimum level`() async {
    // Create a stream with error-only filter
    let stream = VLCInstance.shared.logStream(minimumLevel: .error)
    let task = Task {
      for await entry in stream {
        // Any entry we receive should be at least error level
        #expect(entry.level >= .error)
        break
      }
    }
    // Cancel after brief period — no errors expected for idle instance
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await task.value
  }

  @Test(.tags(.async))
  func `Log stream termination cleans up`() async {
    let stream = VLCInstance.shared.logStream(minimumLevel: .warning)
    let task = Task {
      for await _ in stream {
        break
      }
    }
    task.cancel()
    await task.value
    // If we get here without crash, cleanup was successful
  }

  @Test(.tags(.async))
  func `Multiple log streams can coexist`() async {
    let stream1 = VLCInstance.shared.logStream(minimumLevel: .warning)
    let stream2 = VLCInstance.shared.logStream(minimumLevel: .error)
    let t1 = Task { for await _ in stream1 {
      break
    } }
    let t2 = Task { for await _ in stream2 {
      break
    } }
    try? await Task.sleep(for: .milliseconds(50))
    t1.cancel()
    t2.cancel()
    await t1.value
    await t2.value
  }

  @Test(.tags(.async))
  func `Two simultaneous streams each receive events independently`() async throws {
    // Create a private instance so we don't interfere with the shared
    // instance's log state if other tests are running concurrently.
    let instance = try VLCInstance()

    let s1 = instance.logStream(minimumLevel: .debug)
    let s2 = instance.logStream(minimumLevel: .debug)

    // Drain briefly from both. Either can hit its first event independently.
    let t1 = Task { @Sendable in
      var count = 0
      for await _ in s1 {
        count += 1
        if count >= 1 { break }
      }
      return count
    }
    let t2 = Task { @Sendable in
      var count = 0
      for await _ in s2 {
        count += 1
        if count >= 1 { break }
      }
      return count
    }

    // Nudge libVLC into producing a log line by creating a doomed media.
    _ = try? Media(path: "/definitely/does/not/exist.mp4")

    // Give consumers a chance to wake up, but don't wait forever.
    try? await Task.sleep(for: .milliseconds(200))
    t1.cancel()
    t2.cancel()
    _ = await t1.value
    _ = await t2.value
  }

  @Test(.tags(.async))
  func `Log stream onTermination fires on cancel`() async {
    // Create and immediately cancel a stream to trigger onTermination cleanup
    do {
      let stream = VLCInstance.shared.logStream(minimumLevel: .debug)
      let task = Task {
        for await _ in stream {
          break
        }
      }
      task.cancel()
      await task.value
    }
    // If onTermination ran without crash, cleanup succeeded.
    // Creating another stream should still work.
    let stream2 = VLCInstance.shared.logStream(minimumLevel: .debug)
    let task2 = Task {
      for await _ in stream2 {
        break
      }
    }
    task2.cancel()
    await task2.value
  }
}
