import XCTest

/// Recording writes the live stream to disk while playback continues.
/// Exercises libVLC's stream-to-file path and the `.recordingChanged`
/// event bridge — file I/O during playback is a classic bug source.
final class RecordingUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Recording.playPauseButton]
  }

  private var toggleButton: XCUIElement {
    app.buttons[AccessibilityID.Recording.toggleButton]
  }

  private var savedToLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Recording.savedToLabel]
  }

  func test_smoke_toggleButtonVisibleAndInteractive() {
    launch(route: .recording)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(toggleButton.exists, "Recording toggle button never appeared")
    XCTAssertTrue(toggleButton.isHittable, "Recording toggle not interactive")
    XCTAssertFalse(savedToLabel.exists, "Saved-to label should not exist before first recording")
    assertNoLibraryErrors()
  }

  /// Start recording, wait a few seconds, stop. The `.recordingChanged`
  /// event should fire with a valid path, populating the Saved-to row.
  func test_deep_startStopProducesFilePath() {
    launch(route: .recording)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    toggleButton.tap()
    waitForLabel(toggleButton, equals: "Stop recording", timeout: 5)

    Thread.sleep(forTimeInterval: 2)

    toggleButton.tap()
    waitForLabel(toggleButton, equals: "Start recording", timeout: 5)

    // The recording-stop event should include a non-nil file path.
    XCTAssertTrue(
      savedToLabel.waitForExistence(timeout: 5),
      "Saved-to label never appeared after stop — .recordingChanged event didn't deliver a path"
    )

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .recording)
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
