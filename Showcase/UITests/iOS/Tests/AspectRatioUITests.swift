import XCTest

/// Aspect ratio changes call `Player.aspectRatio = …` which pushes to
/// libVLC's video output. The test surface is small (a picker); focus
/// is on not-crashing and the picker-doesn't-disappear contract.
final class AspectRatioUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AspectRatio.playPauseButton]
  }

  func test_smoke_loadsReachesPlayingWithPicker() {
    launch(route: .aspectRatio)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let pickerID = AccessibilityID.AspectRatio.ratioPicker
    let picker = app.descendants(matching: .any)[pickerID].firstMatch
    XCTAssertTrue(picker.exists, "Aspect ratio picker never appeared")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .aspectRatio)
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
