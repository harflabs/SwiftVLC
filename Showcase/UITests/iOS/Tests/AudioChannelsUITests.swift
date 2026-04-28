import XCTest

/// Channel mode changes push to libVLC's audio output — the bug-magnet
/// subsystem. This suite tests the load + stress paths; exhaustive
/// picker-interaction coverage is deferred until we have a multi-
/// channel fixture.
final class AudioChannelsUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AudioChannels.playPauseButton]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .audioChannels)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .audioChannels)
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
