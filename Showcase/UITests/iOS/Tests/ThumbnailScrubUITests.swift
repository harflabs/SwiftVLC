import XCTest

/// Thumbnail scrubbing uses a pre-generated tile grid, not on-the-fly
/// thumbnails — `media.thumbnail(at:)` takes 1-2 s per call, so a
/// scrub that cancels mid-flight never lands. This suite covers the
/// real UX: tiles load in the background, the nearest tile snaps in
/// during scrub, and the seek commits on release.
final class ThumbnailScrubUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.ThumbnailScrub.playPauseButton]
  }

  private var slider: XCUIElement {
    app.sliders[AccessibilityID.ThumbnailScrub.slider]
  }

  private var previewImage: XCUIElement {
    app.images[AccessibilityID.ThumbnailScrub.previewOverlayImage]
  }

  private var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.ThumbnailScrub.currentTimeLabel]
  }

  // MARK: - Helpers

  /// Parses "M:SS" into seconds. Returns nil on anything else.
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

  /// Page loads, playback reaches `.playing`, the slider appears,
  /// and the current-time label eventually reports a real "M:SS".
  func test_smoke_pageLoadsWithSliderAndKnownDuration() {
    launch(route: .thumbnailScrub)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    XCTAssertTrue(slider.exists, "Scrub slider never appeared")
    XCTAssertTrue(currentTimeLabel.exists, "Current time label missing")
    waitForLabel(currentTimeLabel, notEqual: "--:--", timeout: 8)

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Once the tile grid has loaded at least one entry, scrubbing the
  /// slider makes the preview image appear. Budget: 20 s for libVLC
  /// to decode the first tile (first thumbnail per media carries the
  /// demuxer + decoder warm-up).
  func test_deep_scrubbingShowsPreviewTileOnceLoaded() {
    launch(route: .thumbnailScrub)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTimeLabel, notEqual: "--:--", timeout: 8)

    slider.adjust(toNormalizedSliderPosition: 0.5)

    // The tile loader runs sequentially; the first tile should land
    // within ~3 s on cached media, up to 20 s on cold HLS / remote.
    XCTAssertTrue(
      previewImage.waitForExistence(timeout: 20),
      "Preview tile never appeared after scrub — either loader is stalled or layering is broken"
    )

    assertNoLibraryErrors()
  }

  /// Once tiles exist, scrubbing different positions must keep the
  /// preview visible throughout — the tile snaps to the nearest
  /// cached frame, no new decode work happens on drag.
  func test_deep_scrubbingKeepsPreviewStableAcrossPositions() {
    launch(route: .thumbnailScrub)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTimeLabel, notEqual: "--:--", timeout: 8)

    slider.adjust(toNormalizedSliderPosition: 0.25)
    XCTAssertTrue(previewImage.waitForExistence(timeout: 20), "First preview never loaded")

    // Rapid position changes must all keep a preview visible.
    for target in [CGFloat(0.75), 0.1, 0.9, 0.5] {
      slider.adjust(toNormalizedSliderPosition: target)
      XCTAssertTrue(
        previewImage.exists,
        "Preview disappeared after scrub to \(target) — tile snap should be instant"
      )
    }

    assertNoLibraryErrors()
  }

  /// Releasing the slider must commit the seek — the current-time
  /// label moves toward the drag target.
  func test_deep_releasingSliderSeeksPlayer() {
    launch(route: .thumbnailScrub)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTimeLabel, notEqual: "--:--", timeout: 8)

    // Pause so the player doesn't drift between the scrub and the sample.
    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    let before = seconds(from: currentTimeLabel.label) ?? -1
    slider.adjust(toNormalizedSliderPosition: 0.75)
    Thread.sleep(forTimeInterval: 1)

    let after = seconds(from: currentTimeLabel.label) ?? -1
    XCTAssertGreaterThan(
      after, before,
      "Current-time label didn't advance after scrub release (before=\(before)s, after=\(after)s)"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Performance

  /// Rapid scrubs must be instant — tile snap is O(n) on a dozen
  /// cached images, no libVLC work. `XCTClockMetric` tracks wall-clock
  /// across the storm; `XCTMemoryMetric` pins that memory doesn't
  /// balloon from undead thumbnail tasks.
  func test_perf_rapidScrubsStayInstantAndFlat() {
    launch(route: .thumbnailScrub)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTimeLabel, notEqual: "--:--", timeout: 8)

    // Warm the tile grid with one scrub so `measure` doesn't pay
    // the first-tile decoder cost on iteration 1.
    slider.adjust(toNormalizedSliderPosition: 0.5)
    _ = previewImage.waitForExistence(timeout: 20)

    let targets: [CGFloat] = [0.1, 0.9, 0.3, 0.7, 0.2, 0.8, 0.5, 0.95]

    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
      for target in targets {
        slider.adjust(toNormalizedSliderPosition: target)
      }
    }

    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid scrubs")
    XCTAssertTrue(slider.exists, "Scrub slider vanished after rapid scrubs")

    assertNoLibraryErrors()
  }

  /// First-scrub latency: from slider `.adjust` to visible preview.
  /// Allows 20 s on cold-start (first tile request walks through
  /// demuxer init + decode). A regression that stalled the main
  /// actor would blow past this.
  func test_perf_firstScrubPreviewAppearsWithinBudget() {
    launch(route: .thumbnailScrub)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(currentTimeLabel, notEqual: "--:--", timeout: 8)

    let start = Date()
    slider.adjust(toNormalizedSliderPosition: 0.5)
    XCTAssertTrue(previewImage.waitForExistence(timeout: 20))
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertLessThan(
      elapsed, 20.0,
      "First preview took \(String(format: "%.2f", elapsed)) s — expected < 20 s"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Terminate / relaunch while tiles are loading. Memory must not
  /// climb across cycles — the loader `Task` has to cancel cleanly
  /// when `onDisappear` cancels it.
  func test_stress_presentDismissCyclesDuringTileLoad() {
    launch(route: .thumbnailScrub)
    XCTAssertTrue(slider.waitForExistence(timeout: 5))

    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        slider.adjust(toNormalizedSliderPosition: CGFloat.random(in: 0.1...0.9))
        app.terminate()
        app.launch()
        _ = slider.waitForExistence(timeout: 5)
      }
    }

    assertNoLibraryErrors()
  }

  /// Scrub before the player has reached `.playing`. Race pair with
  /// `SeekingUITests.test_stress_seekBeforePlaybackStarts`: `.task {
  /// player.play(url:) }` and the user dragging must not corrupt
  /// the Player or the tile loader.
  func test_stress_scrubBeforePlaybackStarts() {
    launch(route: .thumbnailScrub)

    XCTAssertTrue(slider.waitForExistence(timeout: 3))
    slider.adjust(toNormalizedSliderPosition: 0.5)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 15)

    assertNoLibraryErrors()
  }
}
