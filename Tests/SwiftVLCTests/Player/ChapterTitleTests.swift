@testable import SwiftVLC
import CustomDump
import Testing

extension Logic {
  struct ChapterTitleTests {
    @Test
    func `Title id returns index`() {
      let title = Title(index: 3, duration: .seconds(60), name: "Chapter 3", isMenu: false, isInteractive: false)
      #expect(title.id == 3)
    }

    @Test
    func `Title is Hashable`() {
      let a = Title(index: 0, duration: .seconds(60), name: "Main", isMenu: false, isInteractive: false)
      let b = Title(index: 0, duration: .seconds(60), name: "Main", isMenu: false, isInteractive: false)
      expectNoDifference(a, b)
    }

    @Test
    func `Title stores properties`() {
      let title = Title(index: 1, duration: .seconds(120), name: "Menu", isMenu: true, isInteractive: true)
      #expect(title.index == 1)
      #expect(title.duration == .seconds(120))
      #expect(title.name == "Menu")
      #expect(title.isMenu == true)
      #expect(title.isInteractive == true)
    }

    @Test
    func `Chapter id returns index`() {
      let chapter = Chapter(index: 5, timeOffset: .seconds(30), duration: .seconds(10), name: "Intro")
      #expect(chapter.id == 5)
    }

    @Test
    func `Chapter is Hashable`() {
      let a = Chapter(index: 0, timeOffset: .zero, duration: .seconds(10), name: nil)
      let b = Chapter(index: 0, timeOffset: .zero, duration: .seconds(10), name: nil)
      expectNoDifference(a, b)
    }

    @Test
    func `Chapter stores properties`() {
      let chapter = Chapter(index: 2, timeOffset: .seconds(60), duration: .seconds(30), name: "Verse")
      #expect(chapter.index == 2)
      #expect(chapter.timeOffset == .seconds(60))
      #expect(chapter.duration == .seconds(30))
      #expect(chapter.name == "Verse")
    }

    @Test(.tags(.mainActor, .async, .integration))
    @MainActor
    func `Player titles empty for simple media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.titles.isEmpty)
      #expect(player.titleCount <= 0)
    }

    @Test(.tags(.mainActor, .async, .integration))
    @MainActor
    func `Player chapters empty for simple media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.chapters().isEmpty)
      #expect(player.chapterCount <= 0)
    }
  }
}
