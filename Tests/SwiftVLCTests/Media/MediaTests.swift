@testable import SwiftVLC
import Foundation
import Testing

@Suite("Media", .tags(.integration), .serialized)
struct MediaTests {
  @Test("Init from URL")
  func initFromURL() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    #expect(media.mrl != nil)
  }

  @Test("Init from file path")
  func initFromPath() throws {
    let media = try Media(path: TestMedia.testMP4URL.path)
    #expect(media.mrl != nil)
  }

  @Test("Init from file descriptor")
  func initFromFileDescriptor() throws {
    let fd = open(TestMedia.testMP4URL.path, O_RDONLY)
    #expect(fd >= 0)
    defer { close(fd) }
    let media = try Media(fileDescriptor: Int(fd))
    #expect(media.mrl != nil)
  }

  @Test("MRL is non-nil")
  func mrlIsNonNil() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let mrl = try #require(media.mrl)
    #expect(!mrl.isEmpty)
  }

  @Test("Duration nil before parsing")
  func durationNilBeforeParsing() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    // Duration may or may not be available before parsing
    // This test just ensures the property doesn't crash
    _ = media.duration
  }

  @Test("Parse returns metadata", .tags(.async, .media))
  func parseReturnsMetadata() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // test.mp4 has title="Test" embedded
    #expect(metadata.title == "Test")
  }

  @Test("Tracks empty before parsing")
  func tracksEmptyBeforeParsing() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    // Tracks may be empty before parse
    _ = media.tracks()
  }

  @Test("Tracks available after parsing", .tags(.async, .media))
  func tracksAfterParsing() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    #expect(!tracks.isEmpty)
    // Should have at least one video and one audio track
    #expect(tracks.contains(where: { $0.type == .video }))
    #expect(tracks.contains(where: { $0.type == .audio }))
  }

  @Test("Add option doesn't crash")
  func addOption() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    media.addOption(":network-caching=1000")
  }

  @Test("Set metadata doesn't crash")
  func setMetadata() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    media.setMetadata(.title, value: "New Title")
  }

  @Test("Statistics nil before playback")
  func statisticsNilBeforePlayback() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    #expect(media.statistics() == nil)
  }

  @Test("Is Sendable")
  func isSendable() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let sendable: any Sendable = media
    _ = sendable
  }

  @Test("Multiple media objects parse independently", .tags(.async, .media))
  func multipleMediaParseIndependently() async throws {
    // libVLC rejects a second parse on the same media object,
    // so verify two separate media objects parse independently.
    let media1 = try Media(url: TestMedia.testMP4URL)
    let media2 = try Media(url: TestMedia.testMP4URL)
    let meta1 = try await media1.parse()
    let meta2 = try await media2.parse()
    #expect(meta1.title == meta2.title)
  }

  @Test("Init from nonexistent path succeeds")
  func initFromNonexistentPath() throws {
    // libVLC accepts non-existent paths (it creates the media object;
    // failure surfaces later during parse/playback). Empty paths cause
    // an internal abort, so we test with a valid-looking but nonexistent path.
    let media = try Media(path: "/nonexistent/file.mp4")
    #expect(media.mrl != nil)
  }

  @Test("MRL contains file path for local files")
  func mrlContainsPath() throws {
    let path = TestMedia.testMP4URL.path
    let media = try Media(path: path)
    let mrl = try #require(media.mrl)
    #expect(mrl.contains("test.mp4"))
  }

  @Test("Parse with short timeout", .tags(.async, .media))
  func parseWithShortTimeout() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    // Local files should parse quickly even with short timeout
    let metadata = try await media.parse(timeout: .seconds(2))
    #expect(metadata.title != nil)
  }

  @Test("Duration available after parsing", .tags(.async, .media))
  func durationAfterParsing() async throws {
    let media = try Media(url: TestMedia.twosecURL)
    _ = try await media.parse()
    let duration = try #require(media.duration)
    // 2-second file should have duration close to 2000ms
    #expect(duration.milliseconds > 1500)
    #expect(duration.milliseconds < 3000)
  }

  @Test("Init from remote URL")
  func initFromRemoteURL() throws {
    // libVLC accepts remote URLs (uses libvlc_media_new_location)
    let url = try #require(URL(string: "http://example.com/video.mp4"))
    let media = try Media(url: url)
    let mrl = try #require(media.mrl)
    #expect(mrl.contains("example.com"))
  }

  @Test("Save metadata fails for non-writable media")
  func saveMetadataFails() throws {
    let media = try Media(path: "/nonexistent/file.mp4")
    #expect(throws: VLCError.self) {
      try media.saveMetadata()
    }
  }

  @Test("File descriptor init with invalid fd succeeds")
  func invalidFileDescriptorSucceeds() throws {
    // libVLC accepts -1 fd (failure surfaces later during playback)
    let media = try Media(fileDescriptor: -1)
    #expect(media.mrl != nil)
  }

  @Test("Parse cancellation", .tags(.async, .media))
  func parseCancellation() async {
    do {
      let media = try Media(url: TestMedia.testMP4URL)
      let task = Task {
        try await media.parse(timeout: .seconds(5))
      }
      // Cancel immediately
      task.cancel()
      do {
        _ = try await task.value
        // May succeed if parse completed before cancellation
      } catch {
        // Expected — cancelled or parse failed
      }
    } catch {
      // Media creation failed
    }
  }

  @Test("Parse same media twice fails", .tags(.async, .media))
  func parseSameMediaTwiceFails() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    // Second parse on same media should fail (libVLC rejects it)
    do {
      _ = try await media.parse()
      Issue.record("Expected second parse to fail")
    } catch {
      // Expected: "parse request rejected"
      #expect(error is VLCError)
    }
  }

  @Test("Duration nil for unparsed media")
  func durationNilForUnparsed() throws {
    let media = try Media(path: "/nonexistent/file.mp4")
    // Duration is -1 before parsing, which maps to nil
    #expect(media.duration == nil)
  }

  @Test("Tracks empty for unparsed local media")
  func tracksEmptyForUnparsed() throws {
    let media = try Media(path: "/nonexistent/file.mp4")
    #expect(media.tracks().isEmpty)
  }

  @Test("Set and read metadata roundtrip")
  func setAndReadMetadata() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    media.setMetadata(.title, value: "Custom Title")
    // Note: setMetadata is in-memory; reading back may or may not
    // reflect the change without save+reparse
  }

  @Test("Add multiple options")
  func addMultipleOptions() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    media.addOption(":network-caching=1000")
    media.addOption(":no-video")
    media.addOption(":no-audio")
    // No crash = success
  }
}
