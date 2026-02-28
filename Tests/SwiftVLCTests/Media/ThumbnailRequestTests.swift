@testable import SwiftVLC
import Foundation
import Testing

@Suite("ThumbnailRequest", .tags(.integration, .media, .async), .serialized, .timeLimit(.minutes(1)))
struct ThumbnailRequestTests {
  @Test("Returns non-empty data")
  func returnsNonEmptyData() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let data = try await media.thumbnail(at: .zero, width: 64, height: 0)
    #expect(!data.isEmpty)
  }

  @Test("PNG magic bytes")
  func pngMagicBytes() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let data = try await media.thumbnail(at: .zero, width: 64, height: 0)
    // PNG files start with 0x89 P N G
    #expect(data.count >= 4)
    #expect(data[0] == 0x89)
    #expect(data[1] == 0x50) // P
    #expect(data[2] == 0x4E) // N
    #expect(data[3] == 0x47) // G
  }

  @Test("Custom dimensions")
  func customDimensions() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let data = try await media.thumbnail(at: .zero, width: 32, height: 32)
    #expect(!data.isEmpty)
  }

  @Test("Cancellation safety")
  func cancellationSafety() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let task = Task {
      try await media.thumbnail(at: .zero, width: 64)
    }
    task.cancel()
    // Should not crash regardless of outcome
    do {
      _ = try await task.value
    } catch {
      // Expected — cancellation or operation failure
    }
  }

  @Test("Audio-only returns error")
  func audioOnlyReturnsError() async {
    do {
      let media = try Media(url: TestMedia.silenceURL)
      _ = try await media.thumbnail(at: .zero, width: 64, timeout: .seconds(3))
      Issue.record("Expected thumbnail generation to fail for audio-only media")
    } catch {
      // Expected — audio files can't generate video thumbnails
    }
  }
}
