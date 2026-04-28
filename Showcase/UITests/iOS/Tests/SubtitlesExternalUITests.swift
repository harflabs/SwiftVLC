import XCTest

/// SubtitlesExternal uses a system file picker (`.fileImporter`).
/// XCUITest can't easily drive the system sheet, so coverage is limited
/// to the load-button being present and interactive.
final class SubtitlesExternalUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.SubtitlesExternal.playPauseButton]
  }

  private var loadButton: XCUIElement {
    app.buttons[AccessibilityID.SubtitlesExternal.loadButton]
  }

  func test_smoke_loadButtonPresentAndInteractive() {
    launch(route: .subtitlesExternal)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // Scroll if the button is below the fold.
    for _ in 0..<4 where !loadButton.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }

    XCTAssertTrue(loadButton.exists, "Load subtitle button never appeared")
    XCTAssertTrue(loadButton.isHittable, "Load subtitle button not interactive")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .subtitlesExternal)
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
