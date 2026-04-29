import XCTest

/// Deinterlacing pushes state + mode to libVLC's video output filter.
/// The test fixture is progressive, so visual effect is nil; the
/// contract tested here is that the filter config calls don't crash.
final class DeinterlacingUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Deinterlacing.playPauseButton]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .deinterlacing)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .deinterlacing)
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
