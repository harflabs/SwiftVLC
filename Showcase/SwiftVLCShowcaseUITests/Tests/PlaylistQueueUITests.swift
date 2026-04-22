import XCTest

/// PlaylistQueue wraps Player in MediaListPlayer. Tests the queue
/// construction path and the present/dismiss lifecycle.
final class PlaylistQueueUITests: ShowcaseUITestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.PlaylistQueue.playPauseButton]
  }

  func test_smoke_queueLoadsAndPlays() {
    launch(route: .playlistQueue)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .playlistQueue)
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
