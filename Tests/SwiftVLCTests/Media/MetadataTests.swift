@testable import SwiftVLC
import Foundation
import Testing

@Suite("Metadata", .tags(.integration, .media))
struct MetadataTests {
  @Test("Parsed title from test MP4", .tags(.async))
  func parsedTitle() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.title == "Test")
  }

  @Test("Parsed artist from test MP4", .tags(.async))
  func parsedArtist() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.artist == "SwiftVLC")
  }

  @Test("Parsed genre from test MP4", .tags(.async))
  func parsedGenre() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.genre == "Testing")
  }

  @Test("Parsed track number from test MP4", .tags(.async))
  func parsedTrackNumber() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.trackNumber == 1)
  }

  @Test("Subscript access", .tags(.async))
  func subscriptAccess() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata[.title] == "Test")
    #expect(metadata[.artist] == "SwiftVLC")
  }

  @Test("Missing keys return nil", .tags(.async))
  func missingKeysNil() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // These fields shouldn't be set in our test file
    #expect(metadata.showName == nil)
    #expect(metadata.season == nil)
    #expect(metadata.episode == nil)
  }

  @Test("MetadataKey allCases count")
  func allCasesCount() {
    #expect(MetadataKey.allCases.count == 26)
  }

  @Test(
    "MetadataKey raw values",
    arguments: [
      (MetadataKey.title, 0),
      (.artist, 1),
      (.genre, 2),
      (.album, 4),
      (.trackNumber, 5),
      (.artworkURL, 15),
      (.discTotal, 25),
    ] as [(MetadataKey, Int)]
  )
  func rawValues(key: MetadataKey, expected: Int) {
    #expect(key.rawValue == expected)
  }

  @Test("Metadata is Equatable")
  func equatable() async throws {
    // Use two separate media objects since libVLC rejects
    // a second parse on the same media object.
    let media1 = try Media(url: TestMedia.testMP4URL)
    let media2 = try Media(url: TestMedia.testMP4URL)
    let meta1 = try await media1.parse()
    let meta2 = try await media2.parse()
    #expect(meta1 == meta2)
  }

  @Test("Duration from parsed metadata", .tags(.async))
  func durationFromMetadata() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // 1-second file
    if let duration = metadata.duration {
      #expect(duration.milliseconds > 500)
      #expect(duration.milliseconds < 2000)
    }
  }

  @Test("Optional int fields", .tags(.async))
  func optionalIntFields() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // discNumber should be nil for our simple test file
    #expect(metadata.discNumber == nil)
  }

  @Test("Metadata is Sendable")
  func isSendable() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    let sendable: any Sendable = metadata
    _ = sendable
  }

  @Test("Artwork URL nil for simple media", .tags(.async))
  func artworkURLNil() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // Simple test files have no artwork
    #expect(metadata.artworkURL == nil)
  }

  @Test("All string fields accessible", .tags(.async))
  func allStringFields() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // Just verify all string properties are accessible without crash
    _ = metadata.album
    _ = metadata.albumArtist
    _ = metadata.date
    _ = metadata.description
    _ = metadata.copyright
    _ = metadata.publisher
    _ = metadata.language
  }

  @Test("Disc number nil for simple media", .tags(.async))
  func discNumberNil() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.discNumber == nil)
  }

  @Test("All MetadataKey subscripts accessible", .tags(.async))
  func allSubscriptsAccessible() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    // Access every key via subscript
    for key in MetadataKey.allCases {
      _ = metadata[key]
    }
  }

  @Test("MetadataKey cValue round-trip")
  func cValueRoundTrip() {
    for key in MetadataKey.allCases {
      let cval = key.cValue
      #expect(cval.rawValue == UInt32(key.rawValue))
    }
  }

  @Test("Season and episode nil for music", .tags(.async))
  func seasonAndEpisodeNil() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.season == nil)
    #expect(metadata.episode == nil)
  }
}
