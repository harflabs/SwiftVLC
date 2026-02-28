@testable import SwiftVLC
import Foundation
import Testing

@Suite("MediaList", .tags(.integration))
struct MediaListTests {
  @Test("Init empty has count zero")
  func initEmptyCountZero() {
    let list = MediaList()
    #expect(list.isEmpty) // swiftlint:disable:this empty_count
  }

  @Test("Append increases count")
  func appendIncreasesCount() throws {
    let list = MediaList()
    let media = try Media(url: TestMedia.testMP4URL)
    try list.append(media)
    #expect(list.count == 1)
  }

  @Test("Append multiple")
  func appendMultiple() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))
    #expect(list.count == 3)
  }

  @Test("Insert at index")
  func insertAtIndex() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.insert(Media(url: TestMedia.silenceURL), at: 1)
    #expect(list.count == 3)
  }

  @Test("Remove at index")
  func removeAtIndex() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.remove(at: 0)
    #expect(list.count == 1)
  }

  // Note: "Insert/remove invalid index" tests are intentionally omitted.
  // libVLC internally aborts (SIGABRT) for out-of-range indices rather
  // than returning an error code, so these can't be tested safely.

  @Test("isReadOnly is false")
  func isReadOnlyFalse() {
    let list = MediaList()
    #expect(list.isReadOnly == false)
  }

  @Test("Thread-safe concurrent appends", .tags(.async))
  func threadSafeConcurrentAppends() async {
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

  @Test("Is Sendable")
  func isSendable() {
    let list = MediaList()
    let sendable: any Sendable = list
    _ = sendable
  }

  @Test("Deinit safety")
  func deinitSafety() throws {
    var list: MediaList? = MediaList()
    try list?.append(Media(url: TestMedia.testMP4URL))
    list = nil
    // No crash = success
  }

  @Test("Count matches items added")
  func countMatchesItemsAdded() throws {
    let list = MediaList()
    #expect(list.isEmpty) // swiftlint:disable:this empty_count
    try list.append(Media(url: TestMedia.testMP4URL))
    #expect(list.count == 1)
    try list.append(Media(url: TestMedia.twosecURL))
    #expect(list.count == 2)
    try list.remove(at: 0)
    #expect(list.count == 1)
    try list.remove(at: 0)
    #expect(list.isEmpty) // swiftlint:disable:this empty_count
  }

  @Test("Insert at beginning")
  func insertAtBeginning() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.insert(Media(url: TestMedia.twosecURL), at: 0)
    #expect(list.count == 2)
  }

  @Test("Multiple remove operations")
  func multipleRemoveOperations() throws {
    let list = MediaList()
    try list.append(Media(url: TestMedia.testMP4URL))
    try list.append(Media(url: TestMedia.twosecURL))
    try list.append(Media(url: TestMedia.silenceURL))
    try list.remove(at: 1) // Remove middle
    #expect(list.count == 2)
    try list.remove(at: 1) // Remove new last
    #expect(list.count == 1)
    try list.remove(at: 0) // Remove remaining
    #expect(list.isEmpty) // swiftlint:disable:this empty_count
  }
}
