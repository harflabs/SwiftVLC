@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

@Suite(.tags(.integration))
struct MediaListExtendedTests {
  // MARK: - subscript access on MediaList

  @Test
  func `Subscript returns media for valid index`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    let item = list[0]
    #expect(item != nil)
    #expect(item?.mrl != nil)
  }

  // Note: Out-of-bounds and empty-list subscript/media(at:) tests are
  // intentionally omitted. libVLC internally aborts (SIGABRT) for
  // out-of-range indices rather than returning NULL.

  // MARK: - media(at:) with valid indices

  @Test
  func `Media at valid index returns Media with MRL`() throws {
    let list = MediaList()
    let url = TestMedia.testMP4URL
    try list.append(Media(url: url))
    let retrieved = list.media(at: 0)
    #expect(retrieved != nil)
    #expect(retrieved?.mrl?.contains("test.mp4") == true)
  }

  @Test
  func `Media at each valid index after multiple appends`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))

    let mrl0 = list.media(at: 0)?.mrl
    let mrl1 = list.media(at: 1)?.mrl
    let mrl2 = list.media(at: 2)?.mrl

    #expect(mrl0?.contains("test.mp4") == true)
    #expect(mrl1?.contains("twosec.mp4") == true)
    #expect(mrl2?.contains("silence.wav") == true)
  }

  // MARK: - media(at:) with invalid indices

  // Note: Out-of-bounds media(at:) tests are intentionally omitted.
  // libVLC internally aborts (SIGABRT) for out-of-range indices.

  // MARK: - isEmpty transitions

  @Test
  func `isEmpty transitions from empty to non-empty to empty`() throws {
    let list = MediaList()
    #expect(list.isEmpty)

    try list.append(Media(url: TestMedia.testMP4URL))
    #expect(!list.isEmpty)

    try list.append(Media(url: TestMedia.twosecURL))
    #expect(!list.isEmpty)

    try list.remove(at: 1)
    #expect(!list.isEmpty)

    try list.remove(at: 0)
    #expect(list.isEmpty)
  }

  // MARK: - isReadOnly for user-created lists

  @Test
  func `isReadOnly is false for user-created list`() {
    let list = MediaList()
    #expect(list.isReadOnly == false)
  }

  // MARK: - Retained media survives list modifications

  @Test
  func `Retained media from subscript survives removal from list`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))

    let retained = list[0]
    #expect(retained != nil)
    let retainedMRL = retained?.mrl

    // Remove the item from the list
    try list.remove(at: 0)
    #expect(list.count == 1)

    // The retained Media should still be valid with the same MRL
    #expect(retained?.mrl == retainedMRL)
    #expect(retained?.mrl?.contains("test.mp4") == true)
  }

  @Test
  func `Retained media from media(at:) survives list clear`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.silenceURL))
    try list.append(Media(url: TestMedia.twosecURL))

    let first = list.media(at: 0)
    let second = list.media(at: 1)

    // Clear the list entirely
    try list.remove(at: 1)
    try list.remove(at: 0)
    #expect(list.isEmpty)

    // Both retained Media objects should still be valid
    #expect(first?.mrl?.contains("silence.wav") == true)
    #expect(second?.mrl?.contains("twosec.mp4") == true)
  }

  // MARK: - withLocked scoped access

  @Test
  func `withLocked provides count`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))

    let lockedCount = list.withLocked { view in
      view.count
    }
    #expect(lockedCount == 2)
  }

  @Test
  func `withLocked count on empty list`() {
    let list = MediaList()
    let lockedCount = list.withLocked { view in
      view.count
    }
    #expect(lockedCount == 0)
  }

  @Test
  func `withLocked media at valid index`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))

    let mrl = list.withLocked { view in
      view.media(at: 0)?.mrl
    }
    #expect(mrl?.contains("test.mp4") == true)
  }

  // Note: withLocked media(at:) with invalid index is intentionally omitted.
  // libVLC internally aborts (SIGABRT) for out-of-range indices.

  @Test
  func `withLocked subscript access`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))

    let mrl = list.withLocked { view in
      view[0]?.mrl
    }
    #expect(mrl?.contains("twosec.mp4") == true)
  }

  // Note: withLocked subscript with invalid index is intentionally omitted.
  // libVLC internally aborts (SIGABRT) for out-of-range indices.

  @Test
  func `withLocked batch read of all MRLs`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))

    let mrls = list.withLocked { view in
      (0..<view.count).compactMap { view.media(at: $0)?.mrl }
    }

    #expect(mrls.count == 3)
    #expect(mrls[0].contains("test.mp4"))
    #expect(mrls[1].contains("twosec.mp4"))
    #expect(mrls[2].contains("silence.wav"))
  }

  @Test
  func `withLocked batch read using subscript`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.silenceURL))

    let mrls = list.withLocked { view in
      (0..<view.count).compactMap { view[$0]?.mrl }
    }

    #expect(mrls.count == 2)
    #expect(mrls[0].contains("test.mp4"))
    #expect(mrls[1].contains("silence.wav"))
  }

  @Test
  func `withLocked batch operations on three items`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))

    let (count, firstMRL, lastMRL) = list.withLocked { view in
      let c = view.count
      let first = view[0]?.mrl
      let last = view[c - 1]?.mrl
      return (c, first, last)
    }

    #expect(count == 3)
    #expect(firstMRL?.contains("test.mp4") == true)
    #expect(lastMRL?.contains("silence.wav") == true)
  }

  @Test
  func `withLocked returns computed value`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))

    let allHaveMRLs = list.withLocked { view in
      (0..<view.count).allSatisfy { view.media(at: $0)?.mrl != nil }
    }

    #expect(allHaveMRLs)
  }
}
