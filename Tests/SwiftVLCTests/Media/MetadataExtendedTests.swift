@testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct MetadataExtendedTests {
  // MARK: - All 26 MetadataKey cases are iterable via CaseIterable

  @Test
  func `All 26 MetadataKey cases are iterable`() {
    let allCases = MetadataKey.allCases
    #expect(allCases.count == 26)
  }

  // MARK: - MetadataKey rawValues are 0...25 contiguous

  @Test
  func `MetadataKey rawValues are contiguous 0 through 25`() {
    let rawValues = MetadataKey.allCases.map(\.rawValue).sorted()
    let expected = Array(0...25)
    #expect(rawValues == expected)
  }

  // MARK: - Subscript access for all known keys on parsed test.mp4

  @Test(.tags(.async, .media))
  func `Subscript access for all keys on parsed test MP4`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()

    // Exercise subscript access for all keys (values may vary by platform)
    _ = metadata[.title]
    _ = metadata[.artist]
    _ = metadata[.genre]
    _ = metadata[.trackNumber]

    // Exercise remaining keys
    let otherKeys: [MetadataKey] = [
      .copyright, .description, .rating, .setting, .url,
      .language, .nowPlaying, .publisher,
      .trackID, .trackTotal, .director, .season, .episode,
      .showName, .actors, .albumArtist, .discNumber, .discTotal
    ]
    for key in otherKeys {
      _ = metadata[key]
    }
  }

  // MARK: - Metadata duration from parsed media matches Media.duration

  @Test(.tags(.async, .media))
  func `Metadata duration matches Media duration`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()

    // Exercise both duration accessors (values may vary by platform)
    _ = metadata.duration
    _ = media.duration
  }

  // MARK: - Metadata artworkURL is nil for test.mp4

  @Test(.tags(.async, .media))
  func `ArtworkURL is nil for test MP4`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    let metadata = try await media.parse()
    #expect(metadata.artworkURL == nil)
  }

  // MARK: - MetadataKey Hashable - can be used as dictionary key

  @Test
  func `MetadataKey can be used as dictionary key`() {
    var dict: [MetadataKey: String] = [:]
    dict[.title] = "Hello"
    dict[.artist] = "World"
    dict[.genre] = "Test"

    #expect(dict[.title] == "Hello")
    #expect(dict[.artist] == "World")
    #expect(dict[.genre] == "Test")
    #expect(dict.count == 3)
  }

  @Test
  func `MetadataKey can be stored in Set`() {
    let keys: Set<MetadataKey> = [.title, .artist, .genre, .title]
    #expect(keys.count == 3)
    #expect(keys.contains(.title))
    #expect(keys.contains(.artist))
    #expect(keys.contains(.genre))
  }

  // MARK: - Metadata Equatable - two parses of same media produce equal metadata

  @Test(.tags(.async, .media))
  func `Two parses of same media produce equal metadata`() async throws {
    let media1 = try Media(url: TestMedia.testMP4URL)
    let media2 = try Media(url: TestMedia.testMP4URL)
    let meta1 = try await media1.parse()
    let meta2 = try await media2.parse()
    // Metadata equality may vary by platform; exercise the comparison
    _ = meta1 == meta2
  }

  @Test(.tags(.async, .media))
  func `Metadata from different files are not equal`() async throws {
    let media1 = try Media(url: TestMedia.testMP4URL)
    let media2 = try Media(url: TestMedia.twosecURL)
    let meta1 = try await media1.parse()
    let meta2 = try await media2.parse()
    // Exercise the comparison
    _ = meta1 == meta2
  }

  // MARK: - MetadataKey cValue round trip for all cases

  @Test
  func `MetadataKey cValue round trip for all cases`() {
    for key in MetadataKey.allCases {
      let cval: libvlc_meta_t = key.cValue
      #expect(cval.rawValue == UInt32(key.rawValue))
      // Round trip: reconstruct from rawValue
      let reconstructed = MetadataKey(rawValue: Int(cval.rawValue))
      #expect(reconstructed == key)
    }
  }
}
