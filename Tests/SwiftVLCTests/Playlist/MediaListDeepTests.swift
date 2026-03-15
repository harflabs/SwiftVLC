@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
struct MediaListDeepTests {
  // MARK: - withLocked returning nil for out-of-bounds via LockedView.media(at:)

  // Note: Direct out-of-bounds access on libVLC media lists causes SIGABRT.
  // We test the withLocked path only where count is checked first.

  @Test
  func `withLocked returns nil when list is empty and no index accessed`() {
    let list = MediaList()
    let result: Media? = list.withLocked { view in
      guard !view.isEmpty else { return nil }
      return view.media(at: 0)
    }
    #expect(result == nil)
  }

  // MARK: - withLocked count after modifications

  @Test
  func `withLocked count reflects appends`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))

    let countBefore = list.withLocked { $0.count }
    #expect(countBefore == 2)

    try list.append(Media(url: TestMedia.silenceURL))

    let countAfter = list.withLocked { $0.count }
    #expect(countAfter == 3)
  }

  @Test
  func `withLocked count reflects removals`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))

    let countBefore = list.withLocked { $0.count }
    #expect(countBefore == 2)

    try list.remove(at: 0)

    let countAfter = list.withLocked { $0.count }
    #expect(countAfter == 1)
  }

  // MARK: - isEmpty true for new list

  @Test
  func `isEmpty true for new list`() {
    let list = MediaList()
    #expect(list.isEmpty == true)
  }

  // MARK: - isEmpty false after append

  @Test
  func `isEmpty false after append`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    #expect(list.isEmpty == false)
  }

  // MARK: - Multiple withLocked calls in sequence

  @Test
  func `Multiple withLocked calls in sequence`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))

    let count1 = list.withLocked { $0.count }
    let count2 = list.withLocked { $0.count }
    let count3 = list.withLocked { $0.count }

    #expect(count1 == 3)
    #expect(count2 == 3)
    #expect(count3 == 3)
  }

  @Test
  func `Sequential withLocked calls return consistent media`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))

    let mrl1 = list.withLocked { $0.media(at: 0)?.mrl }
    let mrl2 = list.withLocked { $0.media(at: 0)?.mrl }

    #expect(mrl1 == mrl2)
    #expect(mrl1?.contains("test.mp4") == true)
  }

  // MARK: - withLocked with empty list returns zero count

  @Test
  func `withLocked with empty list returns zero count`() {
    let list = MediaList()
    let count = list.withLocked { $0.count }
    #expect(count == 0)
  }

  // MARK: - Media from subscript has valid mrl

  @Test
  func `Media from subscript has valid mrl`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))

    let media = list[0]
    #expect(media != nil)
    #expect(media?.mrl != nil)
    #expect(media?.mrl?.isEmpty == false)
  }

  @Test
  func `Media from withLocked subscript has valid mrl`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.silenceURL))

    let mrl = list.withLocked { view in
      view[0]?.mrl
    }
    #expect(mrl != nil)
    #expect(mrl?.contains("silence.wav") == true)
  }
}
