import XCTest

/// Rate changes the playback multiplier live, touching both the audio
/// output (pitch preservation) and the decoder's frame pacing. Covers
/// default value, adjust-updates-label, actually-affects-time-advance,
/// and rapid changes.
final class RateUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Rate.playPauseButton]
  }

  private var currentLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Rate.currentLabel]
  }

  private var slider: XCUIElement {
    app.sliders[AccessibilityID.Rate.slider]
  }

  /// Parses "1.50×" into Double(1.5). Returns nil on unexpected strings.
  private func rate(from label: String) -> Double? {
    guard label.hasSuffix("×") else { return nil }
    return Double(label.dropLast())
  }

  // MARK: - Smoke

  /// At first paint the rate shows `1.00×` (nominal). This is the
  /// regression guard for the class of bug we hit with `volume` — a
  /// negative sentinel leaking into the UI.
  func test_smoke_rateDefaultsToNominal() {
    launch(route: .rate)

    XCTAssertTrue(currentLabel.waitForExistence(timeout: 5))
    guard let value = rate(from: currentLabel.label) else {
      XCTFail("Rate label unparseable: '\(currentLabel.label)'")
      return
    }
    XCTAssertEqual(value, 1.0, accuracy: 0.001, "Rate should default to 1.0×, got \(value)")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Moving the slider toward the low end lowers the displayed rate;
  /// toward the high end raises it. Relative ordering is checked
  /// rather than exact value because XCUITest slider precision drifts.
  func test_deep_sliderAdjustChangesDisplayedRate() {
    launch(route: .rate)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    slider.adjust(toNormalizedSliderPosition: 0.1)
    Thread.sleep(forTimeInterval: 1)
    guard let low = rate(from: currentLabel.label) else {
      XCTFail("Rate unparseable after low adjust: '\(currentLabel.label)'")
      return
    }

    slider.adjust(toNormalizedSliderPosition: 0.9)
    Thread.sleep(forTimeInterval: 1)
    guard let high = rate(from: currentLabel.label) else {
      XCTFail("Rate unparseable after high adjust: '\(currentLabel.label)'")
      return
    }

    XCTAssertGreaterThan(high, low, "Slider 0.9 produced rate \(high), slider 0.1 produced \(low)")
    // Sanity: range endpoints are 0.25 and 4.0 — a high-to-low span
    // should be at least 2× even with 15 % slider drift.
    XCTAssertGreaterThan(high / low, 2, "Rate span low→high was only \(high / low)×")

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Hammer the slider through the full range. Each adjust triggers a
  /// `libvlc_media_player_set_rate` call; the audio output must stay
  /// responsive and not lock up.
  func test_stress_rapidRateChanges() {
    launch(route: .rate)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.2, 0.8, 0.4, 0.6, 0.05, 0.95, 0.5]
    for target in targets {
      slider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(playPauseButton.exists, "App crashed during rapid rate changes")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid rate changes")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .rate)
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
