import XCTest

/// StreamingHLS uses `TestMedia.hls` which is overridden to the local
/// fixture in test mode, so HLS-specific network paths aren't exercised
/// here. Verifies the showcase loads and shows statistics once playback
/// starts.
final class StreamingHLSUITests: ShowcaseUITestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.StreamingHLS.playPauseButton]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .streamingHLS)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .streamingHLS)
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
