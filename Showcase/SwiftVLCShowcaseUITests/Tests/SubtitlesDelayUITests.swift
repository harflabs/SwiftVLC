import XCTest

final class SubtitlesDelayUITests: ShowcaseUITestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.SubtitlesDelay.playPauseButton]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .subtitlesDelay)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .subtitlesDelay)
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
