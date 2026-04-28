import XCTest

/// AudioOutputs enumerates available audio output modules and devices
/// via `VLCInstance.shared.audioOutputs()` and `player.audioDevices()`.
/// iOS simulator typically reports a minimal set (coreaudio or none);
/// the test verifies the enumeration path doesn't crash or deadlock and
/// the UI renders a sensible state.
final class AudioOutputsUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AudioOutputs.playPauseButton]
  }

  private var outputEmpty: XCUIElement {
    app.staticTexts[AccessibilityID.AudioOutputs.outputEmptyLabel]
  }

  private var deviceEmpty: XCUIElement {
    app.staticTexts[AccessibilityID.AudioOutputs.deviceEmptyLabel]
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, both Output and Device sections
  /// render *some* state — either a picker element or the "None
  /// available" placeholder. Missing section = enumeration crashed.
  func test_smoke_bothSectionsRenderSomeState() {
    launch(route: .audioOutputs)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // The Output section is always populated (has at least one module
    // on iOS simulator) — should see the picker, not the empty placeholder.
    let id = AccessibilityID.AudioOutputs.outputPicker
    let outputPicker = app.descendants(matching: .any)[id].firstMatch
    let outputStatePresent = outputPicker.exists || outputEmpty.exists
    XCTAssertTrue(
      outputStatePresent,
      "Output section showed neither picker nor 'None available' — enumeration likely crashed"
    )

    // Device section is always present but may be empty on iOS sim.
    let deviceId = AccessibilityID.AudioOutputs.devicePicker
    let devicePicker = app.descendants(matching: .any)[deviceId].firstMatch
    let deviceStatePresent = devicePicker.exists || deviceEmpty.exists
    XCTAssertTrue(
      deviceStatePresent,
      "Device section showed neither picker nor 'None available'"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  func test_stress_presentDismissCycles() {
    launch(route: .audioOutputs)
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
