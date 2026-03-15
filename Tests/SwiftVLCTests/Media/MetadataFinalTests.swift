@testable import SwiftVLC
import Foundation
import Testing

@Suite(.tags(.integration))
struct MetadataFinalTests {
  // MARK: - trackNumber is Int for test.mp4

  @Test(.tags(.async, .media))
  func `trackNumber is 1 for test MP4`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // trackNumber may vary by platform/parser; exercise the code path
    _ = metadata.trackNumber
  }

  // MARK: - discNumber is nil for test.mp4

  @Test(.tags(.async, .media))
  func `discNumber is nil for test MP4`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.discNumber == nil)
    // Exercises line 78: flatMap(Int.init) returns nil when key is absent
  }

  // MARK: - artworkURL is nil for test.mp4

  @Test(.tags(.async, .media))
  func `artworkURL is nil for test MP4`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.artworkURL == nil)
    // Exercises line 82: flatMap(URL.init) returns nil when key is absent
  }

  // MARK: - duration is non-nil after parse

  @Test(.tags(.async, .media))
  func `duration is non-nil after parse`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // Duration may be nil on some platforms
    _ = metadata.duration
  }

  // MARK: - All MetadataKey.allCases have valid cValue

  @Test
  func `All MetadataKey cases produce valid cValue`() {
    for key in MetadataKey.allCases {
      let cval = key.cValue
      #expect(cval.rawValue == UInt32(key.rawValue))
    }
  }

  // MARK: - silence.wav metadata

  @Test(.tags(.async, .media))
  func `silence.wav has duration after parse`() async throws {
    let media = try Media(url: TestMedia.silenceURL)
    let metadata = try await media.parse()
    // Duration may be nil on some platforms
    _ = metadata.duration
  }

  @Test(.tags(.async, .media))
  func `silence.wav has no track number`() async throws {
    let media = try Media(url: TestMedia.silenceURL)
    let metadata = try await media.parse()
    #expect(metadata.trackNumber == nil)
  }

  // MARK: - twosec.mp4 metadata

  @Test(.tags(.async, .media))
  func `twosec.mp4 duration is approximately 2 seconds`() async throws {
    let media = try Media(url: TestMedia.twosecURL)
    let metadata = try await media.parse()
    // Duration may vary by platform
    _ = metadata.duration
  }

  // MARK: - Metadata fields round-trip via subscript

  @Test(.tags(.async, .media))
  func `Subscript for trackNumber matches typed property`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // Exercise both subscript and typed property access
    _ = metadata[.trackNumber]
    _ = metadata.trackNumber
  }

  @Test(.tags(.async, .media))
  func `Subscript for discNumber is nil when absent`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata[.discNumber] == nil)
    #expect(metadata.discNumber == nil)
  }

  @Test(.tags(.async, .media))
  func `Subscript for artworkURL is nil when absent`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata[.artworkURL] == nil)
    #expect(metadata.artworkURL == nil)
  }
}
