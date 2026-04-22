@testable import SwiftVLC
import Testing

/// Covers `MediaType.description` — a pure switch-to-string mapping
/// exercised by logging and debug output.
@Suite(.tags(.logic))
struct MediaTypeTests {
  @Test
  func `description maps every case to a distinct string`() {
    #expect(MediaType.unknown.description == "unknown")
    #expect(MediaType.file.description == "file")
    #expect(MediaType.directory.description == "directory")
    #expect(MediaType.disc.description == "disc")
    #expect(MediaType.stream.description == "stream")
    #expect(MediaType.playlist.description == "playlist")
  }

  @Test
  func `Every case has a distinct description`() {
    let cases: [MediaType] = [.unknown, .file, .directory, .disc, .stream, .playlist]
    let descriptions = Set(cases.map(\.description))
    #expect(descriptions.count == cases.count, "Each case must stringify uniquely")
  }
}
