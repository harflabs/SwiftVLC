import XCTest

/// SubtitlesSelection exposes `player.subtitleTracks` via a Picker.
/// The local fixture has no subtitle tracks, so the empty-state
/// placeholder is expected; tests verify the Subtitles section renders
/// *some* state (placeholder or picker) — missing state = enumeration
/// crashed.
final class SubtitlesSelectionUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.SubtitlesSelection.playPauseButton]
  }

  private var emptyLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SubtitlesSelection.emptyLabel]
  }

  private func scrollToSubtitles() {
    for _ in 0..<5 where !emptyLabel.exists {
      let id = AccessibilityID.SubtitlesSelection.picker
      if app.descendants(matching: .any)[id].firstMatch.exists { return }
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  func test_smoke_subtitlesSectionRendersState() {
    launch(route: .subtitlesSelection)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToSubtitles()

    let pickerID = AccessibilityID.SubtitlesSelection.picker
    let picker = app.descendants(matching: .any)[pickerID].firstMatch
    XCTAssertTrue(
      emptyLabel.exists || picker.exists,
      "Subtitles section showed neither picker nor 'No subtitle tracks' — enumeration likely crashed"
    )

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .subtitlesSelection)
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
