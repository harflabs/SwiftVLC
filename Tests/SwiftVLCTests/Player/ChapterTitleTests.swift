@testable import SwiftVLC
import Testing

@Suite("ChapterTitle", .tags(.logic))
struct ChapterTitleTests {
  @Test("Title id returns index")
  func titleId() {
    let title = Title(index: 3, duration: .seconds(60), name: "Chapter 3", isMenu: false, isInteractive: false)
    #expect(title.id == 3)
  }

  @Test("Title is Hashable")
  func titleHashable() {
    let a = Title(index: 0, duration: .seconds(60), name: "Main", isMenu: false, isInteractive: false)
    let b = Title(index: 0, duration: .seconds(60), name: "Main", isMenu: false, isInteractive: false)
    #expect(a == b)
  }

  @Test("Title stores properties")
  func titleProperties() {
    let title = Title(index: 1, duration: .seconds(120), name: "Menu", isMenu: true, isInteractive: true)
    #expect(title.index == 1)
    #expect(title.duration == .seconds(120))
    #expect(title.name == "Menu")
    #expect(title.isMenu == true)
    #expect(title.isInteractive == true)
  }

  @Test("Chapter id returns index")
  func chapterId() {
    let chapter = Chapter(index: 5, timeOffset: .seconds(30), duration: .seconds(10), name: "Intro")
    #expect(chapter.id == 5)
  }

  @Test("Chapter is Hashable")
  func chapterHashable() {
    let a = Chapter(index: 0, timeOffset: .zero, duration: .seconds(10), name: nil)
    let b = Chapter(index: 0, timeOffset: .zero, duration: .seconds(10), name: nil)
    #expect(a == b)
  }

  @Test("Chapter stores properties")
  func chapterProperties() {
    let chapter = Chapter(index: 2, timeOffset: .seconds(60), duration: .seconds(30), name: "Verse")
    #expect(chapter.index == 2)
    #expect(chapter.timeOffset == .seconds(60))
    #expect(chapter.duration == .seconds(30))
    #expect(chapter.name == "Verse")
  }

  @Test("Player titles empty for simple media", .tags(.mainActor, .async, .integration))
  @MainActor
  func playerTitlesEmpty() throws {
    let player = try Player()
    #expect(player.titles.isEmpty)
    #expect(player.titleCount <= 0)
  }

  @Test("Player chapters empty for simple media", .tags(.mainActor, .async, .integration))
  @MainActor
  func playerChaptersEmpty() throws {
    let player = try Player()
    #expect(player.chapters().isEmpty)
    #expect(player.chapterCount <= 0)
  }
}
