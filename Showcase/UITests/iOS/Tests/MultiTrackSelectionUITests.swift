import XCTest

/// The showcase advertises `audioTracks` / `subtitleTracks` / `programs`
/// and `@Bindable`-driven selection. Under `fixtureURL` the media is a
/// single-audio-stream MP4 (no subtitles, no programs), so this suite
/// asserts the predictable shape: audio tracks populate, subtitle /
/// program sections fall back to the empty placeholder, nothing
/// crashes. A richer fixture (MKV w/ multi-audio + subs) would unlock
/// selection assertions — tracked in the comment-only TODO below.
final class MultiTrackSelectionUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.MultiTrackSelection.playPauseButton]
  }

  private var audioLoadingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.MultiTrackSelection.audioTracksLoadingLabel]
  }

  private var audioPicker: XCUIElement {
    let id = AccessibilityID.MultiTrackSelection.audioTrackPicker
    return app.descendants(matching: .any)[id].firstMatch
  }

  private var subtitleEmptyLabel: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.MultiTrackSelection.subtitleTracksEmptyLabel]
      .firstMatch
  }

  private var videoLoadingLabel: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.MultiTrackSelection.videoTracksLoadingLabel]
      .firstMatch
  }

  private var programsEmptyLabel: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.MultiTrackSelection.programsEmptyLabel]
      .firstMatch
  }

  // MARK: - Smoke

  /// Page loads and reaches playing. The audio loading placeholder is
  /// replaced by a picker within 10s (single-stream fixture gives
  /// exactly one track).
  func test_smoke_audioTracksResolve() {
    launch(route: .multiTrackSelection)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // The "Loading…" placeholder must be replaced by the picker once
    // `player.audioTracks` is non-empty.
    let resolved = NSPredicate { _, _ in !self.audioLoadingLabel.exists }
    let exp = expectation(for: resolved, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: 10) != .completed {
      XCTFail("audioTracks never populated — 'Loading…' placeholder still visible after 10s")
    }
    XCTAssertTrue(
      audioPicker.exists,
      "Audio track picker not in accessibility tree after tracks loaded"
    )

    assertNoLibraryErrors()
  }

  /// The Subtitles section renders its empty placeholder — the test
  /// fixture has no embedded subtitle streams. Regression guard: if
  /// the guard expression inverts (`!isEmpty`), we'd render a picker
  /// with no entries.
  ///
  /// Programs are intentionally excluded — libVLC populates a default
  /// `Program 0` for MP4 containers (which don't carry MPEG-TS PAT/PMT
  /// structures), so `player.programs.isEmpty` is environment-
  /// dependent and not suitable for a smoke assertion.
  func test_smoke_emptySubtitlePlaceholder() {
    launch(route: .multiTrackSelection)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    XCTAssertTrue(
      subtitleEmptyLabel.waitForExistence(timeout: 8),
      "Subtitles section should show the empty placeholder for the test fixture"
    )

    assertNoLibraryErrors()
  }

  /// Video-variants section resolves — `player.videoTracks` is
  /// non-empty by the time playback reaches `.playing` (same event
  /// that populates audioTracks). Regression guard: the `@Bindable`
  /// wiring on `$bindable.selectedAudioTrack` must not swallow
  /// `.tracksChanged` updates.
  func test_smoke_videoVariantsPopulate() {
    launch(route: .multiTrackSelection)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let resolved = NSPredicate { _, _ in !self.videoLoadingLabel.exists }
    let exp = expectation(for: resolved, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: 10) != .completed {
      XCTFail("videoTracks never populated — 'Loading…' still visible after 10s")
    }

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Present/dismiss cycles. Each cycle creates a fresh Player +
  /// parses tracks. Leak in the `@Observable` graph or an unfinished
  /// `for await` on `player.events` would surface here.
  func test_stress_presentDismissCycles() {
    launch(route: .multiTrackSelection)
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
