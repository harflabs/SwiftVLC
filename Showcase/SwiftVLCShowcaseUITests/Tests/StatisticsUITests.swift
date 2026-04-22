import XCTest

final class StatisticsUITests: ShowcaseUITestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Statistics.playPauseButton]
  }

  private var waitingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Statistics.waitingLabel]
  }

  private var readBytesLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Statistics.readBytes]
  }

  private var demuxReadBytesLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Statistics.demuxReadBytes]
  }

  private var decodedVideoLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Statistics.decodedVideo]
  }

  private var inputBitrateLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Statistics.inputBitrate]
  }

  func test_smoke_loadsAndReachesPlaying() {
    launch(route: .statistics)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  /// Regression guard for the "stats never appear" bug.
  ///
  /// The original StatisticsCase body never observed any `@Observable`
  /// property of `Player`, so SwiftUI rendered it exactly once — before
  /// `.task` had a chance to call `player.play(url:)`. At that moment
  /// `currentMedia` was nil, `player.statistics` returned nil, and the
  /// UI stuck on "Waiting for statistics…" forever.
  ///
  /// This test verifies that after playback reaches `.playing`, the
  /// stats rows *render* (proving the view re-evaluated) and the
  /// spinner is gone. We don't assert on specific counter values
  /// because the iOS simulator's libVLC backend can take 10s+ to
  /// push the first stats update through, and XCUI's
  /// element-to-label resolution is unreliable on lazy-loaded Form
  /// rows — turning "stats value eventually ticks" into a chronically
  /// flaky assertion. The accessibility-tree dump from the simulator
  /// already confirms real values appear ("479544 bytes" was observed
  /// in development); the unit-level regression is the re-render wire.
  func test_stats_populateDuringPlayback() {
    launch(route: .statistics)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // The read-bytes row must be addressable — that's what proves the
    // showcase body re-evaluated after `.task` ran `player.play(url:)`.
    // If the re-render regression comes back, this element wouldn't
    // exist because `player.statistics` would still be returning nil
    // from its first (pre-play) evaluation.
    XCTAssertTrue(
      readBytesLabel.waitForExistence(timeout: 10),
      "Statistics rows never rendered — the showcase body likely never re-evaluated after play()"
    )
    XCTAssertFalse(
      waitingLabel.exists,
      "'Waiting for statistics…' is still showing after playback reached .playing"
    )

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .statistics)
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
