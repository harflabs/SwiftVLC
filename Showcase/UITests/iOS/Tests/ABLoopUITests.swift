import XCTest

/// Covers A-B loop state transitions (off → A set → active → off), the
/// loop actually looping (currentTime should stay inside [A, B] across the
/// B crossing), and stress (rapid mark/reset, tiny loops, present/dismiss).
final class ABLoopUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.ABLoop.playPauseButton]
  }

  private var stateLabel: XCUIElement {
    app.staticTexts[AccessibilityID.ABLoop.stateLabel]
  }

  private var aLabel: XCUIElement {
    app.staticTexts[AccessibilityID.ABLoop.aLabel]
  }

  private var bLabel: XCUIElement {
    app.staticTexts[AccessibilityID.ABLoop.bLabel]
  }

  private var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.ABLoop.currentTimeLabel]
  }

  private var markAButton: XCUIElement {
    app.buttons[AccessibilityID.ABLoop.markAButton]
  }

  private var markBButton: XCUIElement {
    app.buttons[AccessibilityID.ABLoop.markBButton]
  }

  private var resetButton: XCUIElement {
    app.buttons[AccessibilityID.ABLoop.resetButton]
  }

  private func seconds(from label: String) -> Int? {
    let parts = label.split(separator: ":")
    guard
      parts.count == 2,
      let minutes = Int(parts[0]),
      let secs = Int(parts[1])
    else { return nil }
    return minutes * 60 + secs
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, and the loop state is `off` with both
  /// A and B labels empty (`—`).
  func test_smoke_loopStartsOff() {
    launch(route: .abLoop)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(stateLabel, equals: "off", timeout: 5)

    XCTAssertEqual(aLabel.label, "—", "A label should be unset at start, got '\(aLabel.label)'")
    XCTAssertEqual(bLabel.label, "—", "B label should be unset at start, got '\(bLabel.label)'")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Full state machine: Mark A populates the A label but doesn't yet
  /// commit to libVLC (the public API requires both A and B in a single
  /// `set_abloop_time(a, b)` call — libVLC's `abloop_a` state isn't
  /// reachable through `libvlc_media_player_set_abloop_*`). Mark B
  /// commits both and transitions libVLC to `abloop_b` → "active".
  /// Reset tears down both.
  func test_deep_stateMachineTransitions() {
    launch(route: .abLoop)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(stateLabel, equals: "off", timeout: 5)

    // Mark A: Swift state updates, libVLC untouched.
    XCTAssertTrue(markAButton.isHittable, "Mark A not hittable before tap")
    markAButton.tap()
    waitForLabel(aLabel, notEqual: "—", timeout: 3)
    XCTAssertEqual(stateLabel.label, "off", "libVLC state should stay 'off' after Mark A only — public API requires both A and B")
    XCTAssertEqual(bLabel.label, "—", "B label should still be unset after Mark A only")

    // Let playback advance so B > A.
    Thread.sleep(forTimeInterval: 2)

    markBButton.tap()
    waitForLabel(stateLabel, equals: "active", timeout: 3)
    XCTAssertNotEqual(aLabel.label, "—", "A label should stay populated after Mark B")
    XCTAssertNotEqual(bLabel.label, "—", "B label should be populated after Mark B")

    resetButton.tap()
    waitForLabel(stateLabel, equals: "off", timeout: 3)
    XCTAssertEqual(aLabel.label, "—", "A label should clear on Reset")
    XCTAssertEqual(bLabel.label, "—", "B label should clear on Reset")

    assertNoLibraryErrors()
  }

  /// The loop must actually loop: after setting A and B a few seconds
  /// apart, wait past B and verify currentTime has wrapped back into
  /// [A, B]. If the loop trigger is broken, currentTime will keep
  /// advancing past B.
  func test_deep_loopActuallyLoops() {
    launch(route: .abLoop)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // Mark A early in playback.
    XCTAssertTrue(markAButton.isHittable, "Mark A not hittable before tap")
    markAButton.tap()
    waitForLabel(aLabel, notEqual: "—", timeout: 3)
    guard let aSecs = seconds(from: aLabel.label) else {
      XCTFail("A label unparseable: '\(aLabel.label)'")
      return
    }

    // 3-second loop window.
    Thread.sleep(forTimeInterval: 3)
    markBButton.tap()
    waitForLabel(stateLabel, equals: "active", timeout: 3)
    guard let bSecs = seconds(from: bLabel.label) else {
      XCTFail("B label unparseable: '\(bLabel.label)'")
      return
    }

    let window = bSecs - aSecs
    XCTAssertGreaterThan(window, 0, "Loop window collapsed: A=\(aSecs) B=\(bSecs)")

    // Wait past B — player should have crossed the loop edge at least
    // once. Check currentTime falls back inside [A, B + 1s tolerance].
    Thread.sleep(forTimeInterval: Double(window) + 2)

    guard let observed = seconds(from: currentTimeLabel.label) else {
      XCTFail("currentTime unparseable: '\(currentTimeLabel.label)'")
      return
    }
    XCTAssertGreaterThanOrEqual(
      observed, aSecs,
      "currentTime \(observed)s is before A (\(aSecs)s) — loop overshot backwards"
    )
    XCTAssertLessThanOrEqual(
      observed, bSecs + 1,
      "currentTime \(observed)s ran past B (\(bSecs)s) — loop trigger didn't fire"
    )
    XCTAssertEqual(
      stateLabel.label, "active",
      "Loop state regressed to '\(stateLabel.label)' while waiting past B"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Mark/Reset in rapid succession. Exercises the setABLoop →
  /// resetABLoop pair and the abLoopState observer chain.
  func test_stress_rapidMarkAndReset() {
    launch(route: .abLoop)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<10 {
      markAButton.tap()
      Thread.sleep(forTimeInterval: 0.3)
      markBButton.tap()
      Thread.sleep(forTimeInterval: 0.3)
      resetButton.tap()
      Thread.sleep(forTimeInterval: 0.3)
    }

    waitForLabel(stateLabel, equals: "off", timeout: 3)

    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid mark/reset cycles")

    assertNoLibraryErrors()
  }

  /// A and B marked in the same tick (back-to-back taps). The loop
  /// window is nearly zero — libVLC must handle this gracefully without
  /// spinning the decoder thread.
  func test_stress_tinyLoopWindow() {
    launch(route: .abLoop)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    markAButton.tap()
    markBButton.tap()

    Thread.sleep(forTimeInterval: 3)

    XCTAssertTrue(playPauseButton.exists, "App died on near-zero-width A-B loop")
    XCTAssertTrue(playPauseButton.isHittable)

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .abLoop)
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
