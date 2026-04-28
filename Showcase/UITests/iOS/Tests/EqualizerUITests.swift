import XCTest

/// Equalizer attaches a real-time filter to the player's audio output.
/// Every preamp or band mutation re-applies the equalizer to libVLC
/// (it copies settings rather than retaining the reference), so rapid
/// slider drags flood libVLC with reattach calls.
final class EqualizerUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Equalizer.playPauseButton]
  }

  private var preampSlider: XCUIElement {
    app.sliders[AccessibilityID.Equalizer.preampSlider]
  }

  private var preampGainLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Equalizer.preampGainLabel]
  }

  private func scrollToPreamp() {
    for _ in 0..<5 where !preampSlider.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  func test_smoke_loadsAndReachesPlayingWithEqualizerAttached() {
    launch(route: .equalizer)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  /// Rapid preamp drags re-attach the equalizer on each value change
  /// — `Equalizer.preamp` writes through to libVLC and pings the
  /// installed onChange handler, which re-applies to the player.
  /// libVLC's audio output must remain coherent across the churn.
  func test_stress_rapidPreampChanges() {
    launch(route: .equalizer)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToPreamp()

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.0, 1.0, 0.25, 0.75]
    for target in targets {
      preampSlider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(playPauseButton.exists, "App died during rapid preamp changes")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid preamp changes")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .equalizer)
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
