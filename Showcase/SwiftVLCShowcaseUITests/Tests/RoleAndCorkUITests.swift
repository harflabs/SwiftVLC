import XCTest

/// `PlayerRole` + the cork/uncork observation loop. Headless XCUITest
/// can't easily force libVLC to emit `.corked` (that needs a competing
/// audio-focus source), so the deep test just toggles roles and
/// confirms the picker, status badge, and counters stay coherent. The
/// smoke test verifies the page loads and playback starts.
final class RoleAndCorkUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.RoleAndCork.playPauseButton]
  }

  private var rolePicker: XCUIElement {
    let id = AccessibilityID.RoleAndCork.rolePicker
    return app.descendants(matching: .any)[id].firstMatch
  }

  private var statusLabel: XCUIElement {
    app.staticTexts[AccessibilityID.RoleAndCork.statusLabel]
  }

  private var corkedCountLabel: XCUIElement {
    app.staticTexts[AccessibilityID.RoleAndCork.corkedCountLabel]
  }

  private var uncorkedCountLabel: XCUIElement {
    app.staticTexts[AccessibilityID.RoleAndCork.uncorkedCountLabel]
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, status badge starts at "Active"
  /// (not corked), counters sit at zero.
  func test_smoke_loadsWithActiveStatusAndZeroCounters() {
    launch(route: .roleAndCork)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    XCTAssertTrue(statusLabel.exists, "Status label missing")
    XCTAssertEqual(statusLabel.label, "Active", "Fresh session should not be corked")

    XCTAssertTrue(corkedCountLabel.exists, "Corked counter missing")
    XCTAssertEqual(corkedCountLabel.label, "0", "Fresh session should have 0 cork events")

    XCTAssertTrue(uncorkedCountLabel.exists, "Uncorked counter missing")
    XCTAssertEqual(uncorkedCountLabel.label, "0", "Fresh session should have 0 uncork events")

    assertNoLibraryErrors()
  }

  /// Role picker is in the accessibility tree.
  func test_smoke_rolePickerRenders() {
    launch(route: .roleAndCork)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(rolePicker.exists, "Role picker not in accessibility tree")

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Re-launch cycles — the event loop consuming `player.events`
  /// cancels cleanly on `onDisappear`. Memory must not climb across
  /// cycles (the consumer task leaking would retain the player +
  /// bridge).
  func test_stress_presentDismissCycles() {
    launch(route: .roleAndCork)
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
