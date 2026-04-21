import XCTest

/// Chapters enumerates `player.chapters(forTitle:)`. The local fixture
/// has no chapters, so the empty placeholder path is the happy case.
/// Verifies the Chapters section renders *some* state (empty or picker
/// + prev/next buttons) and doesn't crash.
final class ChaptersUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Chapters.playPauseButton]
  }

  private var emptyLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Chapters.emptyLabel]
  }

  func test_smoke_chaptersSectionRendersState() {
    launch(route: .chapters)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // Scroll so the Chapters section is in view.
    for _ in 0..<4 where !emptyLabel.exists {
      let pickerID = AccessibilityID.Chapters.picker
      if app.descendants(matching: .any)[pickerID].firstMatch.exists { break }
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }

    let pickerID = AccessibilityID.Chapters.picker
    let picker = app.descendants(matching: .any)[pickerID].firstMatch
    XCTAssertTrue(
      emptyLabel.exists || picker.exists,
      "Chapters section showed neither picker nor 'No chapters in this media'"
    )

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .chapters)
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))

    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        app.terminate()
        app.launch()
        _ = playPauseButton.waitForExistence(timeout: 5)
      }
    }

    assertNoLibraryErrors()
  }
}
