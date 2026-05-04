@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  struct MediaListTests {
    @Test
    func `Init empty has count zero`() {
      let list = MediaList()
      #expect(list.isEmpty)
    }

    @Test
    func `Append increases count`() throws {
      let list = MediaList()
      let media = try Media(url: TestMedia.testMP4URL)
      try list.append(media)
      #expect(list.count == 1)
    }

    @Test
    func `Append multiple`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))
      try list.append(Media(url: TestMedia.silenceURL))
      #expect(list.count == 3)
    }

    @Test
    func `Insert at index`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))
      try list.insert(Media(url: TestMedia.silenceURL), at: 1)
      #expect(list.count == 3)
    }

    @Test
    func `Remove at index`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))
      try list.remove(at: 0)
      #expect(list.count == 1)
    }

    @Test
    func `Insert and remove invalid index throw before reaching libVLC`() throws {
      let list = MediaList()
      let media = try Media(url: TestMedia.testMP4URL)
      #expect(throws: VLCError.self) {
        try list.insert(media, at: 1)
      }
      #expect(throws: VLCError.self) {
        try list.remove(at: 0)
      }
    }

    @Test
    func `isReadOnly is false`() {
      let list = MediaList()
      #expect(list.isReadOnly == false)
    }

    @Test(.tags(.async))
    func `Thread-safe concurrent appends`() async {
      let list = MediaList()
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
          group.addTask {
            do {
              let media = try Media(url: TestMedia.testMP4URL)
              try list.append(media)
            } catch {
              // Ignore errors — we're testing thread safety
            }
          }
        }
      }
      #expect(list.count == 10)
    }

    @Test
    func `Is Sendable`() {
      let list = MediaList()
      let sendable: any Sendable = list
      _ = sendable
    }

    @Test
    func `Deinit safety`() throws {
      var list: MediaList? = MediaList()
      try list?.append(Media(url: TestMedia.testMP4URL))
      list = nil
      // No crash = success
    }

    @Test
    func `Count matches items added`() throws {
      let list = MediaList()
      #expect(list.isEmpty)
      try list.append(Media(url: TestMedia.testMP4URL))
      #expect(list.count == 1)
      try list.append(Media(url: TestMedia.twosecURL))
      #expect(list.count == 2)
      try list.remove(at: 0)
      #expect(list.count == 1)
      try list.remove(at: 0)
      #expect(list.isEmpty)
    }

    @Test
    func `Insert at beginning`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.insert(Media(url: TestMedia.twosecURL), at: 0)
      #expect(list.count == 2)
    }

    @Test
    func `Multiple remove operations`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))
      try list.append(Media(url: TestMedia.silenceURL))
      try list.remove(at: 1) // Remove middle
      #expect(list.count == 2)
      try list.remove(at: 1) // Remove new last
      #expect(list.count == 1)
      try list.remove(at: 0) // Remove remaining
      #expect(list.isEmpty)
    }

    @Test
    func `Retaining existing pointer exposes the same underlying list`() throws {
      let original = MediaList()
      try original.append(Media(url: TestMedia.testMP4URL))

      let retained = MediaList(retaining: original.pointer)
      #expect(retained.count == 1)

      try retained.append(Media(url: TestMedia.twosecURL))

      #expect(original.count == 2)
      #expect(retained.count == 2)
    }

    @Test
    func `Media lookup returns nil outside list bounds`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))

      #expect(list.media(at: -1) == nil)
      #expect(list.media(at: 1) == nil)
      #expect(list[Int.max] == nil)
    }

    @Test
    func `Locked view exposes a consistent snapshot`() throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))

      let mrls = list.withLocked { view in
        #expect(view.count == 2)
        #expect(view.isEmpty == false)
        #expect(view.media(at: -1) == nil)
        #expect(view[2] == nil)
        return [
          view[0]?.mrl,
          view.media(at: 1)?.mrl
        ]
      }

      #expect(mrls[0]?.contains("test.mp4") == true)
      #expect(mrls[1]?.contains("twosec.mp4") == true)
    }
  }
}
