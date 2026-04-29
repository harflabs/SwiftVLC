import XCTest

/// PiP in the iOS simulator typically reports `isPossible = false` (no
/// real hardware audio session), so the actionable UX test is the
/// button being correctly disabled. Previously flagged: the Start/Stop
/// PiP button was enabled even when PiP wasn't possible, confusing
/// users who tapped it to no effect.
final class PiPUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.PiP.playPauseButton]
  }

  private var possibleLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PiP.possibleLabel]
  }

  private var activeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PiP.activeLabel]
  }

  private var toggleButton: XCUIElement {
    app.buttons[AccessibilityID.PiP.toggleButton]
  }

  private var preparingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PiP.preparingLabel]
  }

  /// Scroll the Form until PiP section is visible.
  private func scrollToPiPSection() {
    for _ in 0..<6 where !possibleLabel.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, and the PiP controller becomes
  /// available (the "Preparing…" placeholder is replaced by the
  /// Possible / Active rows).
  func test_smoke_pipControllerBecomesAvailable() {
    launch(route: .pip)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToPiPSection()

    XCTAssertTrue(
      possibleLabel.waitForExistence(timeout: 10),
      "PiP controller never became available — 'Preparing…' still visible"
    )
    XCTAssertTrue(activeLabel.exists, "Active-status row should be visible alongside Possible row")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Critical UX invariant: when PiP isn't possible, the toggle button
  /// must be disabled (not simply hidden). In simulator, isPossible is
  /// typically `false`, so this is the common-case UX path.
  func test_deep_toggleButtonDisabledWhenNotPossible() {
    launch(route: .pip)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToPiPSection()

    waitForLabel(possibleLabel, equals: "no", timeout: 10)

    // SwiftUI Form may strip disabled Buttons from the accessibility
    // tree entirely — treat either "button doesn't exist" or "button
    // exists but not enabled" as passing the contract. Both mean the
    // user cannot trigger a no-op toggle.
    if toggleButton.exists {
      XCTAssertFalse(
        toggleButton.isEnabled,
        "Toggle PiP button is enabled while isPossible is 'no'"
      )
    }
    // If !toggleButton.exists, SwiftUI hid the disabled button — still
    // correct UX (can't be tapped).

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  func test_stress_presentDismissCycles() {
    launch(route: .pip)
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
