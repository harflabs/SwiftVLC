import XCTest

/// Volume is one of the first real-world bugs users notice: it must show a
/// sensible value from the very first paint, never go negative, and survive
/// rapid changes and mute toggles without losing the underlying level.
final class VolumeUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Volume.playPauseButton]
  }

  private var slider: XCUIElement {
    app.sliders[AccessibilityID.Volume.slider]
  }

  private var levelLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Volume.level]
  }

  private var muteToggle: XCUIElement {
    app.switches[AccessibilityID.Volume.muteToggle]
  }

  // MARK: - Helpers

  /// Parses "42%" or "100%" into Int. Returns nil on unexpected strings.
  private func percent(from label: String) -> Int? {
    guard label.hasSuffix("%") else { return nil }
    return Int(label.dropLast())
  }

  // MARK: - Smoke

  /// On first paint, the level label must be a sensible percentage —
  /// never negative, never wildly above 125. This is the regression
  /// guard for the "I hear audio but the screen shows -100%" bug: the
  /// libVLC getter returns a sentinel value before the audio output
  /// is initialized, and that sentinel must not leak into the UI.
  func test_smoke_levelIsSensibleAtLoad() {
    launch(route: .volume)

    XCTAssertTrue(levelLabel.waitForExistence(timeout: 5), "Level label never appeared")

    guard let pct = percent(from: levelLabel.label) else {
      XCTFail("Level label unparseable: '\(levelLabel.label)'")
      return
    }
    XCTAssertGreaterThanOrEqual(pct, 0, "Volume rendered as negative: \(pct)%")
    XCTAssertLessThanOrEqual(pct, 125, "Volume exceeded maximum 125%: \(pct)%")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Moving the slider updates the level label to a value that reflects
  /// the new position — not the pre-adjust value and not the sentinel.
  func test_deep_sliderAdjustUpdatesLevel() {
    launch(route: .volume)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(levelLabel.waitForExistence(timeout: 5))

    slider.adjust(toNormalizedSliderPosition: 0.1)
    Thread.sleep(forTimeInterval: 1)
    guard let low = percent(from: levelLabel.label) else {
      XCTFail("Level unparseable after low adjust: '\(levelLabel.label)'")
      return
    }
    XCTAssertGreaterThanOrEqual(low, 0)

    slider.adjust(toNormalizedSliderPosition: 0.9)
    Thread.sleep(forTimeInterval: 1)
    guard let high = percent(from: levelLabel.label) else {
      XCTFail("Level unparseable after high adjust: '\(levelLabel.label)'")
      return
    }
    XCTAssertGreaterThan(high, low, "Slider 0.9 (\(high)%) did not exceed slider 0.1 (\(low)%)")

    assertNoLibraryErrors()
  }

  /// Muting must not reset the underlying volume to 0 — toggling mute
  /// off should restore the previous slider position.
  func test_deep_mutePreservesLevel() {
    launch(route: .volume)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(levelLabel.waitForExistence(timeout: 5))

    // Set a known level.
    slider.adjust(toNormalizedSliderPosition: 0.5)
    Thread.sleep(forTimeInterval: 1)
    guard let before = percent(from: levelLabel.label) else {
      XCTFail("Level unparseable before mute: '\(levelLabel.label)'")
      return
    }

    // Mute, wait, unmute.
    muteToggle.tap()
    Thread.sleep(forTimeInterval: 1)
    muteToggle.tap()
    Thread.sleep(forTimeInterval: 1)

    guard let after = percent(from: levelLabel.label) else {
      XCTFail("Level unparseable after mute cycle: '\(levelLabel.label)'")
      return
    }
    XCTAssertEqual(after, before, "Mute/unmute cycle changed level from \(before)% to \(after)%")

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Rapidly churn the slider. Each adjust triggers a
  /// `libvlc_audio_set_volume` call; the player must stay responsive
  /// and the label must converge to a sensible final value.
  func test_stress_rapidVolumeChanges() {
    launch(route: .volume)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let targets: [CGFloat] = [0.1, 0.9, 0.2, 0.8, 0.3, 0.7, 0.4, 0.6, 0.5, 0.05, 0.95]
    for target in targets {
      slider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(playPauseButton.exists, "App crashed during rapid volume changes")
    guard let final = percent(from: levelLabel.label) else {
      XCTFail("Level unparseable after rapid adjusts: '\(levelLabel.label)'")
      return
    }
    XCTAssertGreaterThanOrEqual(final, 0, "Volume rendered as negative: \(final)%")
    XCTAssertLessThanOrEqual(final, 125, "Volume exceeded max: \(final)%")

    assertNoLibraryErrors()
  }

  /// Hammer the mute toggle. libVLC's `libvlc_audio_set_mute` races
  /// against the audio output thread; the wrapper must stay coherent.
  func test_stress_rapidMuteToggle() {
    launch(route: .volume)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(muteToggle.waitForExistence(timeout: 5))

    for _ in 0..<15 {
      muteToggle.tap()
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(muteToggle.exists, "Mute toggle vanished after rapid toggling")
    XCTAssertTrue(muteToggle.isHittable, "Mute toggle stopped responding")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .volume)
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
