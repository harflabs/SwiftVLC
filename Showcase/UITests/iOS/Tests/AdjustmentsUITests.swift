import XCTest

/// Video adjustments access libVLC's filter chain via the non-copyable
/// `VideoAdjustments` borrow (`player.withAdjustments { $0... }`).
/// Exercises the borrowed-view mutation path and live filter reconfig.
final class AdjustmentsUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Adjustments.playPauseButton]
  }

  private var enabledToggle: XCUIElement {
    app.switches[AccessibilityID.Adjustments.enabledToggle]
  }

  private var brightnessSlider: XCUIElement {
    app.sliders[AccessibilityID.Adjustments.brightnessSlider]
  }

  private func scrollToAdjustments() {
    for _ in 0..<5 where !enabledToggle.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .adjustments)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_rapidBrightnessChanges() {
    launch(route: .adjustments)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToAdjustments()

    // Enable first so brightness writes actually reach libVLC.
    enabledToggle.tap()
    Thread.sleep(forTimeInterval: 0.5)

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.0, 1.0]
    for target in targets {
      brightnessSlider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after brightness churn")
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .adjustments)
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
