import XCTest

/// Marquee renders text over video via libVLC's overlay filter. The
/// Swift API uses a non-copyable borrowed view accessed through
/// `player.withMarquee { $0.... }`. This suite exercises enable/disable
/// and opacity churn — both re-configure the overlay filter live.
final class MarqueeUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Marquee.playPauseButton]
  }

  private var enabledToggle: XCUIElement {
    app.switches[AccessibilityID.Marquee.enabledToggle]
  }

  private var opacitySlider: XCUIElement {
    app.sliders[AccessibilityID.Marquee.opacitySlider]
  }

  private func scrollToMarqueeSection() {
    for _ in 0..<5 where !enabledToggle.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .marquee)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  /// Toggle marquee enabled → re-enters `player.withMarquee { ... }`.
  /// Each toggle re-configures the overlay filter.
  func test_stress_rapidEnableToggle() {
    launch(route: .marquee)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToMarqueeSection()

    for _ in 0..<10 {
      enabledToggle.tap()
    }

    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid marquee toggle")
    assertNoLibraryErrors()
  }

  /// Opacity slider drags write through `player.withMarquee { $0.opacity = … }`
  /// each tick — worst-case stress on the non-copyable borrow path.
  func test_stress_rapidOpacityChanges() {
    launch(route: .marquee)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToMarqueeSection()

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.0, 1.0, 0.25, 0.75]
    for target in targets {
      opacitySlider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after opacity churn")
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .marquee)
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
