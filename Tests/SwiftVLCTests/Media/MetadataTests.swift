@testable import CLibVLC
@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.media)) struct MetadataTests {
    @Test(.tags(.async))
    func `Parsed title from test MP4`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata.title == "Test")
    }

    @Test(.tags(.async))
    func `Parsed artist from test MP4`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata.artist == "SwiftVLC")
    }

    @Test(.tags(.async))
    func `Parsed genre from test MP4`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata.genre == "Testing")
    }

    @Test(.tags(.async))
    func `Parsed track number from test MP4`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata.trackNumber == 1)
    }

    @Test(.tags(.async))
    func `Subscript access`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata[.title] == "Test")
      #expect(metadata[.artist] == "SwiftVLC")
    }

    @Test(.tags(.async))
    func `Missing keys return nil`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      // These fields shouldn't be set in our test file
      #expect(metadata.showName == nil)
      #expect(metadata.season == nil)
      #expect(metadata.episode == nil)
    }

    @Test
    func `MetadataKey allCases count`() {
      #expect(MetadataKey.allCases.count == 26)
    }

    @Test(
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
    func `MetadataKey raw values`(key: MetadataKey, expected: Int) {
      #expect(key.rawValue == expected)
    }

    @Test
    func `Metadata is Equatable`() async throws {
      // Use two separate media objects since libVLC rejects
      // a second parse on the same media object.
      let media1 = try Media(url: TestMedia.testMP4URL)
      let media2 = try Media(url: TestMedia.testMP4URL)
      let meta1 = try await media1.parse()
      let meta2 = try await media2.parse()
      #expect(meta1 == meta2)
    }

    @Test(.tags(.async))
    func `Duration from parsed metadata`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      // 1-second file
      if let duration = metadata.duration {
        #expect(duration.milliseconds > 500)
        #expect(duration.milliseconds < 2000)
      }
    }

    @Test(.tags(.async))
    func `Optional int fields`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      // discNumber should be nil for our simple test file
      #expect(metadata.discNumber == nil)
    }

    @Test
    func `Metadata is Sendable`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      let sendable: any Sendable = metadata
      _ = sendable
    }

    @Test(.tags(.async))
    func `Artwork URL nil for simple media`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      // Simple test files have no artwork
      #expect(metadata.artworkURL == nil)
    }

    @Test(.tags(.async))
    func `All string fields accessible`() async throws {
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

    @Test(.tags(.async))
    func `Disc number nil for simple media`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata.discNumber == nil)
    }

    @Test(.tags(.async))
    func `All MetadataKey subscripts accessible`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      // Access every key via subscript
      for key in MetadataKey.allCases {
        _ = metadata[key]
      }
    }

    @Test
    func `MetadataKey cValue round-trip`() {
      for key in MetadataKey.allCases {
        let cval = key.cValue
        #expect(cval.rawValue == UInt32(key.rawValue))
      }
    }

    @Test(.tags(.async))
    func `Season and episode nil for music`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      #expect(metadata.season == nil)
      #expect(metadata.episode == nil)
    }
  }
}
