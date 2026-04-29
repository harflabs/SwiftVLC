import XCTest

/// Lifecycle exercises `.task(id:)` — swapping the source identifier
/// cancels the in-flight `player.play(url:)` task and runs a fresh one.
/// The interesting surfaces are clean-teardown (no leaks) and state
/// recovery across re-launches.
final class LifecycleUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Lifecycle.playPauseButton]
  }

  // MARK: - Smoke

  /// Page loads, reaches playing via the `.task(id: source)`
  /// auto-launch path.
  func test_smoke_autoPlayOnLoad() {
    launch(route: .lifecycle)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Re-launch the app, which re-runs `.task(id:)` on every fresh
  /// mount and re-creates the `Player` from scratch. Memory should
  /// plateau.
  func test_stress_presentDismissCycles() {
    launch(route: .lifecycle)
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
