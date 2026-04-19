@testable import SwiftVLC
import Synchronization
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct MediaListFinalTests {
  // MARK: - init(retaining:) via subscript round-trip

  @Test
  func `Media retrieved via subscript wraps a retained pointer`() throws {
    let list = MediaList()
    let original = try Media(url: TestMedia.testMP4URL)
    let originalMRL = original.mrl
    try list.append(original)

    // subscript calls media(at:) which calls Media(retaining:)
    let retrieved = list[0]
    #expect(retrieved != nil)
    #expect(retrieved?.mrl == originalMRL)
  }

  @Test
  func `media(at:) returns Media with valid mrl`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.silenceURL))

    let first = list.media(at: 0)
    let second = list.media(at: 1)

    #expect(first != nil)
    #expect(second != nil)
    #expect(first?.mrl?.contains("test.mp4") == true)
    #expect(second?.mrl?.contains("silence.wav") == true)
  }

  // MARK: - withLocked LockedView.media(at:) returns valid Media

  @Test
  func `withLocked media at valid index returns Media with mrl`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.twosecURL))

    let media = list.withLocked { view in
      view.media(at: 0)
    }
    #expect(media != nil)
    #expect(media?.mrl?.contains("twosec.mp4") == true)
  }

  @Test
  func `withLocked subscript returns Media with mrl`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))

    let media = list.withLocked { view in
      view[0]
    }
    #expect(media != nil)
    #expect(media?.mrl?.contains("test.mp4") == true)
  }

  // MARK: - Remove all items and verify empty state

  @Test
  func `Remove all items leaves list empty`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))
    #expect(list.count == 3)

    try list.remove(at: 2)
    try list.remove(at: 1)
    try list.remove(at: 0)

    #expect(list.isEmpty)
    #expect(list.isEmpty)
  }

  // MARK: - Insert and verify order with media(at:)

  @Test
  func `Insert at beginning preserves order`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL)) // index 0
    try list.append(Media(url: TestMedia.silenceURL)) // index 1
    try list.insert(Media(url: TestMedia.twosecURL), at: 0) // becomes index 0

    #expect(list.count == 3)
    #expect(list.media(at: 0)?.mrl?.contains("twosec.mp4") == true)
    #expect(list.media(at: 1)?.mrl?.contains("test.mp4") == true)
    #expect(list.media(at: 2)?.mrl?.contains("silence.wav") == true)
  }

  @Test
  func `Insert in middle preserves order`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL)) // index 0
    try list.append(Media(url: TestMedia.silenceURL)) // index 1
    try list.insert(Media(url: TestMedia.twosecURL), at: 1) // becomes index 1

    #expect(list.count == 3)
    #expect(list.media(at: 0)?.mrl?.contains("test.mp4") == true)
    #expect(list.media(at: 1)?.mrl?.contains("twosec.mp4") == true)
    #expect(list.media(at: 2)?.mrl?.contains("silence.wav") == true)
  }

  // MARK: - Retained media survives list deallocation

  @Test
  func `Media from media(at:) survives list deallocation`() throws {
    var list: MediaList? = MediaList()
    try list?.append(Media(url: TestMedia.testMP4URL))

    let retained = try #require(list?.media(at: 0))
    let mrl = retained.mrl

    list = nil // Deallocate the list

    // The retained Media should still be valid because init(retaining:) bumped refcount
    #expect(retained.mrl == mrl)
    #expect(retained.mrl?.contains("test.mp4") == true)
  }

  // MARK: - withLocked batch retrieval returns all Media

  @Test
  func `withLocked batch retrieval of all media items`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))

    let items = list.withLocked { view in
      (0..<view.count).compactMap { view.media(at: $0) }
    }

    #expect(items.count == 3)
    #expect(items[0].mrl?.contains("test.mp4") == true)
    #expect(items[1].mrl?.contains("twosec.mp4") == true)
    #expect(items[2].mrl?.contains("silence.wav") == true)
  }

  // MARK: - LockedView count matches list count

  @Test
  func `LockedView count matches list count after modifications`() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))

    let lockedCount = list.withLocked { view in view.count }
    #expect(lockedCount == list.count)

    try list.remove(at: 0)
    let lockedCountAfter = list.withLocked { view in view.count }
    #expect(lockedCountAfter == list.count)
    #expect(lockedCountAfter == 1)
  }
}
