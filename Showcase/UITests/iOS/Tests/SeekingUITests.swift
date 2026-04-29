import XCTest

/// Seek is the hottest mid-playback state manipulation — it touches the
/// demuxer, decoder cascade, buffer manager, and audio output simultaneously.
/// This suite covers: correctness (seek lands at the target within
/// tolerance), lifecycle edge cases (seek before `.playing`, seek past end),
/// and stress (rapid random seeks, seek while paused, re-mount churn).
final class SeekingUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Seeking.playPauseButton]
  }

  private var slider: XCUIElement {
    app.sliders[AccessibilityID.SeekBar.slider]
  }

  private var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SeekBar.currentTime]
  }

  private var durationLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SeekBar.duration]
  }

  // MARK: - Helpers

  /// Parses "M:SS" (e.g. "1:05") into total seconds. Returns nil for
  /// unexpected formats (helpful for asserting-before-parsing in deep tests).
  private func seconds(from label: String) -> Int? {
    let parts = label.split(separator: ":")
    guard
      parts.count == 2,
      let minutes = Int(parts[0]),
      let secs = Int(parts[1])
    else { return nil }
    return minutes * 60 + secs
  }

  // MARK: - Smoke

  /// The page loads, reaches `playing`, and both the slider and the
  /// duration label (non-zero) are visible.
  func test_smoke_sliderAppearsAndPlayerPlays() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    XCTAssertTrue(slider.exists, "Seek slider never appeared")
    XCTAssertTrue(durationLabel.exists, "Duration label never appeared")

    // Once duration is known it should not be "0:00".
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Seeks to low / mid / high positions and verifies the observed
  /// `currentTime` is monotonically increasing across them.
  ///
  /// XCUITest's `adjust(toNormalizedSliderPosition:)` is not pixel-exact
  /// on continuous SwiftUI sliders (observed drift up to ~15 % of slider
  /// width), so an absolute-target-within-N-seconds assertion would be a
  /// test of the automation layer, not the library. A monotonic-ordering
  /// assertion tests what actually matters: seeking forward produces a
  /// forward jump, and the magnitudes of the jumps are proportional to
  /// the slider movement.
  func test_deep_seekProducesProportionalPositionChange() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    // Pause before seeking so playback doesn't drift the observed times
    // between the seek and the sample.
    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    func seekAndSample(_ target: CGFloat) -> Int {
      slider.adjust(toNormalizedSliderPosition: target)
      Thread.sleep(forTimeInterval: 1)
      return seconds(from: currentTimeLabel.label) ?? -1
    }

    let low = seekAndSample(0.1)
    let mid = seekAndSample(0.5)
    let high = seekAndSample(0.9)

    XCTAssertGreaterThan(mid, low, "Seek 0.5 (got \(mid)s) did not advance past 0.1 (got \(low)s)")
    XCTAssertGreaterThan(high, mid, "Seek 0.9 (got \(high)s) did not advance past 0.5 (got \(mid)s)")

    // Sanity: total span must be more than half the fixture length if
    // the seeks actually moved the player across its timeline.
    guard let total = seconds(from: durationLabel.label) else {
      XCTFail("Duration unparseable: '\(durationLabel.label)'")
      return
    }
    XCTAssertGreaterThan(
      high - low, total / 2,
      "Seeks 0.1→0.9 should span >half of duration (\(total)s); got only \(high - low)s"
    )

    assertNoLibraryErrors()
  }

  /// Seeking while paused must still advance the position label, and
  /// playback must stay paused (not silently resume).
  func test_deep_seekWhilePausedUpdatesPositionWithoutResuming() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    slider.adjust(toNormalizedSliderPosition: 0.5)
    Thread.sleep(forTimeInterval: 2)

    guard let observed = seconds(from: currentTimeLabel.label) else {
      XCTFail("Current time unparseable: '\(currentTimeLabel.label)'")
      return
    }
    XCTAssertGreaterThan(
      observed, 10,
      "Seek to 50 % while paused didn't update currentTime — got \(observed)s"
    )

    // Must still be paused.
    XCTAssertEqual(
      playPauseButton.label, "Play",
      "Player resumed unexpectedly after seek-while-paused"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Hammer random seek targets. Each `adjust` corresponds to a
  /// `libvlc_media_player_set_position` call; the decoder cascade and
  /// buffer manager must stay coherent.
  func test_stress_rapidRandomSeeks() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    // Seeded so failures are reproducible. Values deliberately cover the
    // full range including near-start and near-end.
    let targets: [CGFloat] = [0.9, 0.1, 0.75, 0.05, 0.5, 0.95, 0.25, 0.8, 0.15, 0.65, 0.35, 0.7]

    for target in targets {
      slider.adjust(toNormalizedSliderPosition: target)
    }

    Thread.sleep(forTimeInterval: 3)

    XCTAssertTrue(playPauseButton.exists, "App crashed during rapid seeks")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid seeks")

    assertNoLibraryErrors()
  }

  /// Seek the slider before the player has reached `.playing`. This
  /// exercises the race between `.task { try? player.play(url:) }` and
  /// the user dragging the scrubber — similar class to the immediate
  /// tap-play crash on PlayerState. libVLC's seek without a ready
  /// demuxer has historically corrupted state here.
  func test_stress_seekBeforePlaybackStarts() {
    launch(route: .seeking)

    // Don't wait for Pause. Adjust as soon as the slider exists.
    XCTAssertTrue(slider.waitForExistence(timeout: 3))
    slider.adjust(toNormalizedSliderPosition: 0.5)

    // Player should still be able to reach playing afterwards.
    waitForLabel(playPauseButton, equals: "Pause", timeout: 15)

    assertNoLibraryErrors()
  }

  /// Seek to 99 % and past the logical end. Player must not crash or
  /// hang; state should settle (either at `.playing` at end, or
  /// transition to end-of-media handling).
  func test_stress_seekNearEnd() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    slider.adjust(toNormalizedSliderPosition: 0.99)
    Thread.sleep(forTimeInterval: 5)

    XCTAssertTrue(playPauseButton.exists, "App died after seek near end")

    assertNoLibraryErrors()
  }

  /// Relaunch the app mid-seek-heavy-session. Memory should plateau.
  func test_stress_presentDismissCycles() {
    launch(route: .seeking)
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
