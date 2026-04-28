import XCTest

/// AudioDelay writes to `player.audioDelay` on every slider tick.
/// Rapid churn exercises libVLC's audio-output timing adjustment path.
final class AudioDelayUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AudioDelay.playPauseButton]
  }

  private var slider: XCUIElement {
    app.sliders[AccessibilityID.AudioDelay.slider]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .audioDelay)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(slider.exists, "Delay slider never appeared")
    assertNoLibraryErrors()
  }

  func test_stress_rapidDelayChanges() {
    launch(route: .audioDelay)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.0, 1.0]
    for target in targets {
      slider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid delay changes")
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .audioDelay)
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
