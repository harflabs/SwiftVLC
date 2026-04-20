@testable import SwiftVLC
import Foundation
import Testing

@Suite(
  .tags(.integration, .media, .async),
  .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"),
  .timeLimit(.minutes(1))
)
struct ThumbnailRequestTests {
  @Test
  func `Returns non-empty data`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let data = try await media.thumbnail(at: .zero, width: 64, height: 0)
    #expect(!data.isEmpty)
  }

  @Test
  func `PNG magic bytes`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let data = try await media.thumbnail(at: .zero, width: 64, height: 0)
    // PNG files start with 0x89 P N G
    #expect(data.count >= 4)
    #expect(data[0] == 0x89)
    #expect(data[1] == 0x50) // P
    #expect(data[2] == 0x4E) // N
    #expect(data[3] == 0x47) // G
  }

  @Test
  func `Custom dimensions`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let data = try await media.thumbnail(at: .zero, width: 32, height: 32)
    #expect(!data.isEmpty)
  }

  @Test
  func `Cancellation completes promptly`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let completed = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        let task = Task {
          try await media.thumbnail(at: .zero, width: 64)
        }
        task.cancel()
        do {
          _ = try await task.value
        } catch {
          // Expected — cancellation or operation failure
        }
        return true
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(3))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }

    #expect(completed, "Cancelled thumbnail request should not hang indefinitely")
  }

  @Test
  func `Concurrent thumbnails on the same media stay isolated`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    async let first = media.thumbnail(at: .zero, width: 64, height: 0)
    async let second = media.thumbnail(at: .milliseconds(250), width: 64, height: 0)
    let thumbnails = try await [first, second]
    #expect(thumbnails.count == 2)
    #expect(thumbnails.allSatisfy { !$0.isEmpty })
  }

  @Test(.tags(.async))
  func `Queued thumbnail coordinator cancellation completes promptly`() async throws {
    let coordinator = ThumbnailCoordinator()
    try await coordinator.acquire()
    defer {
      Task {
        await coordinator.release()
      }
    }

    let completed = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        let task = Task {
          do {
            try await coordinator.acquire()
            await coordinator.release()
          } catch {
            // Expected cancellation path
          }
        }
        task.cancel()
        await task.value
        return true
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(1))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }

    #expect(completed, "Queued acquire should stop waiting as soon as it is cancelled")
  }

  @Test
  func `Audio-only returns error`() async {
    do {
      let media = try Media(url: TestMedia.silenceURL)
      _ = try await media.thumbnail(at: .zero, width: 64, timeout: .seconds(3))
      Issue.record("Expected thumbnail generation to fail for audio-only media")
    } catch {
      // Expected — audio files can't generate video thumbnails
    }
  }
}
