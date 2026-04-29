import XCTest

/// Viewpoint exercises `player.updateViewpoint(_:)` which creates a
/// non-escapable `Viewpoint` value per call. The showcase media isn't
/// 360°, so the visible effect is nil; the contract tested here is
/// that the API calls don't crash or leak.
final class ViewpointUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Viewpoint.playPauseButton]
  }

  private var yawSlider: XCUIElement {
    app.sliders[AccessibilityID.Viewpoint.yawSlider]
  }

  private func scrollToViewpoint() {
    for _ in 0..<5 where !yawSlider.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .viewpoint)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_rapidYawChanges() {
    launch(route: .viewpoint)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToViewpoint()

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.0, 1.0]
    for target in targets {
      yawSlider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after yaw churn")
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .viewpoint)
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
