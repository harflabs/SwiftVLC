import XCTest

/// Snapshot writes a PNG to disk asynchronously and the showcase waits
/// for the `.snapshotTaken` event before loading the file. This suite
/// covers the happy path (button produces an image), rapid captures
/// (queued events don't collide), and lifecycle (present/dismiss).
final class SnapshotUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Snapshot.playPauseButton]
  }

  private var takeSnapshotButton: XCUIElement {
    app.buttons[AccessibilityID.Snapshot.takeSnapshotButton]
  }

  private var snapshotImage: XCUIElement {
    app.images[AccessibilityID.Snapshot.snapshotImage]
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, both buttons are hittable, no image
  /// yet.
  func test_smoke_buttonsAppearWithoutSnapshot() {
    launch(route: .snapshot)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(takeSnapshotButton.exists, "Take-snapshot button never appeared")
    XCTAssertTrue(takeSnapshotButton.isHittable, "Take-snapshot button not interactive")
    XCTAssertFalse(snapshotImage.exists, "Snapshot image should not exist before first capture")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Tap Take snapshot → the `.snapshotTaken` event fires → PNG gets
  /// loaded and the Image appears in the "Last snapshot" section.
  func test_deep_captureProducesImage() {
    launch(route: .snapshot)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    takeSnapshotButton.tap()

    XCTAssertTrue(
      snapshotImage.waitForExistence(timeout: 10),
      "Snapshot image never appeared after capture"
    )

    assertNoLibraryErrors()
  }

  /// Multiple captures in succession must replace the displayed image
  /// without the view dropping out — the `.snapshotTaken` event stream
  /// is shared and must not accumulate stale state.
  func test_deep_multipleCapturesReplaceImage() {
    launch(route: .snapshot)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    takeSnapshotButton.tap()
    XCTAssertTrue(snapshotImage.waitForExistence(timeout: 10), "First snapshot never rendered")

    Thread.sleep(forTimeInterval: 1)
    takeSnapshotButton.tap()
    Thread.sleep(forTimeInterval: 5)
    XCTAssertTrue(snapshotImage.exists, "Snapshot image disappeared after second capture")

    takeSnapshotButton.tap()
    Thread.sleep(forTimeInterval: 5)
    XCTAssertTrue(snapshotImage.exists, "Snapshot image disappeared after third capture")

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Hammer the snapshot button. libVLC's snapshot path queues frames;
  /// rapid requests shouldn't crash or block the player.
  func test_stress_rapidCaptures() {
    launch(route: .snapshot)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<5 {
      takeSnapshotButton.tap()
    }

    Thread.sleep(forTimeInterval: 3)

    XCTAssertTrue(playPauseButton.exists, "App died during rapid captures")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid captures")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .snapshot)
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
