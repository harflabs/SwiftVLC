@testable import SwiftVLC
import Foundation
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
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

  // Note: "Insert/remove invalid index" tests are intentionally omitted.
  // libVLC internally aborts (SIGABRT) for out-of-range indices rather
  // than returning an error code, so these can't be tested safely.

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
}
