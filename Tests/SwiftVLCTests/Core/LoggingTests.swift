@testable import SwiftVLC
import Testing

@Suite("Logging", .tags(.integration), .serialized, .timeLimit(.minutes(1)))
struct LoggingTests {
  @Test(
    "Log level raw values",
    arguments: [
      (LogLevel.debug, Int32(0)),
      (.notice, Int32(2)),
      (.warning, Int32(3)),
      (.error, Int32(4))
    ] as [(LogLevel, Int32)]
  )
  func logLevelRawValues(level: LogLevel, expected: Int32) {
    #expect(level.rawValue == expected)
  }

  @Test("Log level Comparable ordering")
  func logLevelComparableOrdering() {
    #expect(LogLevel.debug < .notice)
    #expect(LogLevel.notice < .warning)
    #expect(LogLevel.warning < .error)
  }

  @Test(
    "Log level descriptions",
    arguments: [
      (LogLevel.debug, "debug"),
      (.notice, "notice"),
      (.warning, "warning"),
      (.error, "error"),
    ] as [(LogLevel, String)]
  )
  func logLevelDescriptions(level: LogLevel, expected: String) {
    #expect(level.description == expected)
  }

  @Test("LogEntry stores properties")
  func logEntryStoresProperties() {
    let entry = LogEntry(level: .warning, message: "test msg", module: "http")
    #expect(entry.level == .warning)
    #expect(entry.message == "test msg")
    #expect(entry.module == "http")
  }

  @Test("LogEntry module can be nil")
  func logEntryModuleCanBeNil() {
    let entry = LogEntry(level: .error, message: "oops", module: nil)
    #expect(entry.module == nil)
  }

  @Test("Log stream returns AsyncStream", .tags(.async))
  func logStreamReturnsAsyncStream() async {
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

  @Test("Log stream filters minimum level", .tags(.async))
  func logStreamFiltersMinimumLevel() async {
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

  @Test("Log stream termination cleans up", .tags(.async))
  func logStreamTerminationCleansUp() async {
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

  @Test("Multiple log streams can coexist", .tags(.async))
  func multipleLogStreamsCanCoexist() async {
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

  @Test("Deprecated logStream function", .tags(.async))
  func deprecatedLogStreamFunction() async {
    // Verify the deprecated free function still works
    let stream = SwiftVLC.logStream(minimumLevel: .error)
    let task = Task {
      for await _ in stream {
        break
      }
    }
    task.cancel()
    await task.value
  }

  @Test("Log stream onTermination fires on cancel", .tags(.async))
  func logStreamOnTerminationFires() async {
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
