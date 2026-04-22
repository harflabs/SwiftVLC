import XCTest

final class EventsUITests: ShowcaseUITestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Events.playPauseButton]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .events)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .events)
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
