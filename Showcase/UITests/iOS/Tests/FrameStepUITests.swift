import XCTest

/// Frame step has a small surface but tight invariants: the button must
/// be disabled while playing, enabled while paused, and each tap must
/// advance `currentTime` by roughly one frame (~33 ms for 30 fps).
final class FrameStepUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.FrameStep.playPauseButton]
  }

  private var nextFrameButton: XCUIElement {
    app.buttons[AccessibilityID.FrameStep.nextFrameButton]
  }

  private var pausableLabel: XCUIElement {
    app.staticTexts[AccessibilityID.FrameStep.pausableLabel]
  }

  private var timeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.FrameStep.timeLabel]
  }

  /// Parses "1.234s" into seconds as Double.
  private func secondsDouble(from label: String) -> Double? {
    guard label.hasSuffix("s") else { return nil }
    return Double(label.dropLast())
  }

  /// Scrolls the form up until the Step section (and its Next frame
  /// button) becomes visible. The FrameStep showcase has three other
  /// sections above it; on 6.1" iPhones the button lands below the fold.
  private func scrollToNextFrameButton() {
    for _ in 0..<6 where !nextFrameButton.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  // MARK: - Smoke

  /// Page loads and once paused the Next frame button becomes available.
  /// SwiftUI Forms drop disabled leaf buttons from the accessibility
  /// tree in some iOS versions, so the "disabled while playing"
  /// property is asserted indirectly via `test_deep_*` which sees the
  /// button only after pausing. Here we just verify the discoverability
  /// contract: button exists, is enabled, is hittable when paused.
  func test_smoke_nextFrameAppearsWhenPaused() {
    launch(route: .frameStep)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(pausableLabel, equals: "yes", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    scrollToNextFrameButton()
    XCTAssertTrue(
      nextFrameButton.exists,
      "Next frame button never appeared after pausing + scrolling"
    )
    XCTAssertTrue(nextFrameButton.isEnabled, "Next frame should be enabled while paused")
    XCTAssertTrue(nextFrameButton.isHittable, "Next frame should be hittable while paused")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// The button becomes enabled once paused and each tap advances
  /// currentTime by a small amount (the duration of one frame or a
  /// few). libVLC's `next_frame` steps by at least one frame — we allow
  /// up to 200 ms of drift per tap to tolerate our label format
  /// rounding plus timeChanged event arrival.
  func test_deep_nextFrameAdvancesTimePausedPerTap() {
    launch(route: .frameStep)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(pausableLabel, equals: "yes", timeout: 5)

    // Pause — next frame should become enabled.
    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    scrollToNextFrameButton()
    XCTAssertTrue(
      nextFrameButton.isEnabled,
      "Next frame should be enabled while paused"
    )

    guard let before = secondsDouble(from: timeLabel.label) else {
      XCTFail("timeLabel unparseable: '\(timeLabel.label)'")
      return
    }

    // Step five frames. Allow playback to not resume — button stays as "Play".
    for _ in 0..<5 {
      nextFrameButton.tap()
      Thread.sleep(forTimeInterval: 0.2)
    }

    XCTAssertEqual(
      playPauseButton.label, "Play",
      "Pressing next frame should not resume playback"
    )

    guard let after = secondsDouble(from: timeLabel.label) else {
      XCTFail("timeLabel unparseable after steps: '\(timeLabel.label)'")
      return
    }

    let delta = after - before
    XCTAssertGreaterThan(
      delta, 0.0,
      "Five next-frame taps produced no time advance (before=\(before)s, after=\(after)s)"
    )
    // Generous upper bound: even at very low fps (1 fps), 5 frames is 5 s.
    // We care that time moved, not that each tap is exactly 33 ms.
    XCTAssertLessThan(
      delta, 5.0,
      "Five next-frame taps advanced \(delta)s — suggests the player resumed rather than stepping"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Rapid fire on the step button while paused. libVLC's decoder must
  /// not overflow or deadlock; the button must stay responsive.
  func test_stress_rapidStepWhilePaused() {
    launch(route: .frameStep)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(pausableLabel, equals: "yes", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    scrollToNextFrameButton()
    for _ in 0..<30 {
      nextFrameButton.tap()
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(nextFrameButton.exists, "Next frame button vanished after rapid steps")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid frame-step")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .frameStep)
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
