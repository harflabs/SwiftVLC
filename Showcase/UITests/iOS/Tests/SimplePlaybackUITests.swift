import XCTest

/// Smoke / deep / stress coverage for the SimplePlayback case study.
///
/// Tests assert both UI behavior (via accessibility identifiers) and library
/// cleanliness (via the captured log file). Most launch deep-linked to
/// `SimplePlaybackCase`; the navigation regression starts at the root list.
final class SimplePlaybackUITests: ShowcaseIOSTestCase {
  /// Inherits `@MainActor` from `ShowcaseIOSTestCase` so XCUI APIs are
  /// callable directly without isolation hops.
  private var videoView: XCUIElement {
    app.otherElements[AccessibilityID.SimplePlayback.videoView]
  }

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.SimplePlayback.playPauseButton]
  }

  private var currentTime: XCUIElement {
    app.staticTexts[AccessibilityID.SimplePlayback.currentTime]
  }

  private var duration: XCUIElement {
    app.staticTexts[AccessibilityID.SimplePlayback.duration]
  }

  // MARK: - Smoke

  /// The case study opens, the player view appears, and within 10s media
  /// starts playing (the play/pause button label flips from `Play` to
  /// `Pause`).
  func test_smoke_playerLoadsAndStartsPlaying() {
    launch(route: .simplePlayback)

    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5), "Play/pause button never appeared")
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Exercises the full happy path: media loads, time advances, pause freezes
  /// the clock, resume continues from the same point.
  func test_deep_playPauseAndTimeProgression() {
    launch(route: .simplePlayback)

    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(duration, notEqual: "—", timeout: 5)
    waitForLabel(currentTime, notEqual: "00:00", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    // libVLC's `timeChanged` events for the pre-pause window can still be
    // in flight when the state flip lands. Give the event queue a moment
    // to drain, then sample; the subsequent 2s must not advance the label.
    Thread.sleep(forTimeInterval: 1)
    let timeAfterSettle = currentTime.label

    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(
      currentTime.label, timeAfterSettle,
      "Time advanced from \(timeAfterSettle) to \(currentTime.label) while paused"
    )

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Pause", timeout: 3)
    waitForLabel(currentTime, notEqual: timeAfterSettle, timeout: 5)

    assertNoLibraryErrors()
  }

  /// Recreates the manual failure mode: open Simple Playback from the root
  /// list, pop it, then open it again. The video must still render real pixels
  /// after SwiftUI has dismantled one `VideoSurface` and created another.
  func test_regression_navigationBackAndForthKeepsVideoRendering() {
    launchAtRoot()

    openSimplePlaybackFromRoot()
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTime, notEqual: "00:00", timeout: 10)
    assertRendersNonBlackFrame(videoView, timeout: 10)

    backButton().tap()
    XCTAssertTrue(simplePlaybackLink().waitForExistence(timeout: 5))

    openSimplePlaybackFromRoot()
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTime, notEqual: "00:00", timeout: 10)
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Hammer the play/pause button. Catches races in `togglePlayPause()`,
  /// dropped state events, libVLC API misuse under rapid calls.
  func test_stress_rapidPlayPause() {
    launch(route: .simplePlayback)

    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<25 {
      playPauseButton.tap()
    }

    // The app must still be alive and the button must still be hittable.
    XCTAssertTrue(playPauseButton.exists, "Play/pause button vanished after rapid taps")
    XCTAssertTrue(playPauseButton.isHittable, "Play/pause button is no longer interactive")

    assertNoLibraryErrors()
  }

  /// Re-launch the app a handful of times. Each cycle creates and destroys a
  /// fresh `Player`, so resident memory should plateau, not grow.
  /// `XCTMemoryMetric` records baselines per cycle in the xcresult bundle.
  func test_stress_presentDismissCycles() {
    launch(route: .simplePlayback)
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

  /// Long-running playback. The clock must never stall for more than 10s.
  /// 30s default; bump locally for deeper confidence.
  func test_stress_longRunning() {
    launch(route: .simplePlayback)

    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let totalSeconds: TimeInterval = 30
    let pollInterval: TimeInterval = 5
    let stallTolerance = 2

    let started = Date()
    var lastObserved = currentTime.label
    var stallCount = 0

    while Date().timeIntervalSince(started) < totalSeconds {
      Thread.sleep(forTimeInterval: pollInterval)
      let now = currentTime.label
      if now == lastObserved {
        stallCount += 1
        XCTAssertLessThan(
          stallCount, stallTolerance,
          "Time stalled at \(now) for >\(pollInterval * Double(stallTolerance))s"
        )
      } else {
        stallCount = 0
        lastObserved = now
      }
    }

    assertNoLibraryErrors()
  }

  /// Send the app to background and bring it back. The player must survive
  /// every cycle and remain interactive.
  func test_stress_backgroundForeground() {
    launch(route: .simplePlayback)

    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<2 {
      XCUIDevice.shared.press(.home)
      Thread.sleep(forTimeInterval: 2)
      app.activate()
      Thread.sleep(forTimeInterval: 2)
      XCTAssertTrue(playPauseButton.exists, "Play/pause button gone after background round-trip")
    }

    assertNoLibraryErrors()
  }

  private func openSimplePlaybackFromRoot() {
    let link = simplePlaybackLink()
    XCTAssertTrue(link.waitForExistence(timeout: 5), "Simple Playback link never appeared")
    link.tap()
  }

  private func simplePlaybackLink() -> XCUIElement {
    app.buttons["Simple playback"].firstMatch
  }

  private func backButton() -> XCUIElement {
    app.navigationBars.buttons.element(boundBy: 0)
  }
}
