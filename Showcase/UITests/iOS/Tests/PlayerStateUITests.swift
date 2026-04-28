import XCTest

/// PlayerState is the foundation every other case study depends on — if
/// state transitions are wrong, every other showcase inherits those bugs.
/// This suite is intentionally the most thorough in the project: state
/// reporting, pausable/seekable flag correctness, race-prone input timing,
/// lifecycle cycling, and long-running stability.
///
/// Every test launches deep-linked to `PlayerStateCase` and asserts via
/// accessibility identifiers on visible labels plus the library log file.
final class PlayerStateUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var videoView: XCUIElement {
    app.otherElements[AccessibilityID.PlayerState.videoView]
  }

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.PlayerState.playPauseButton]
  }

  private var stateLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PlayerState.stateLabel]
  }

  private var seekableLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PlayerState.seekableLabel]
  }

  private var pausableLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PlayerState.pausableLabel]
  }

  // MARK: - Smoke

  /// The page loads, the player reports `playing` within 10s, no library
  /// errors fire along the way.
  func test_smoke_stateReachesPlaying() {
    launch(route: .playerState)

    XCTAssertTrue(stateLabel.waitForExistence(timeout: 5), "State label never appeared")
    waitForLabel(stateLabel, equals: "playing", timeout: 10)

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Observes the entire play → pause → resume → play cycle via the
  /// `state` label. Every transition must produce the expected string.
  func test_deep_playPauseResumeCycle() {
    launch(route: .playerState)

    waitForLabel(stateLabel, equals: "playing", timeout: 10)

    // Pause.
    playPauseButton.tap()
    waitForLabel(stateLabel, equals: "paused", timeout: 5)

    // Resume.
    playPauseButton.tap()
    waitForLabel(stateLabel, equals: "playing", timeout: 5)

    assertNoLibraryErrors()
  }

  /// `isSeekable` and `isPausable` must flip from `no` to `yes` once media
  /// is ready, then remain `yes` across pause/resume (a local mp4 with a
  /// valid index is always seekable and pausable while loaded).
  func test_deep_seekableAndPausableFlagsTrackState() {
    launch(route: .playerState)

    waitForLabel(stateLabel, equals: "playing", timeout: 10)
    waitForLabel(seekableLabel, equals: "yes", timeout: 5)
    waitForLabel(pausableLabel, equals: "yes", timeout: 5)

    playPauseButton.tap()
    waitForLabel(stateLabel, equals: "paused", timeout: 5)

    // Flags must not regress while paused — the media is still loaded.
    XCTAssertEqual(seekableLabel.label, "yes", "isSeekable regressed to no while paused")
    XCTAssertEqual(pausableLabel.label, "yes", "isPausable regressed to no while paused")

    playPauseButton.tap()
    waitForLabel(stateLabel, equals: "playing", timeout: 5)

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Repro for the "tap play repeatedly immediately on open" crash: the
  /// `.task` that starts playback races with back-to-back user taps, and
  /// `togglePlayPause` fires against a `Player` that is still transitioning
  /// out of `.idle`/`.opening`. libVLC's audio-output assertion
  /// (`stream->timing.pause_date == VLC_TICK_INVALID` in
  /// `src/audio_output/dec.c:876`) has been observed terminating the
  /// process under this sequence, preceded by
  /// `libvlc stream filter error: reading while paused (buggy demux?)`.
  ///
  /// Test expectation: the app survives every tap. If this crashes, the
  /// xcresult bundle captures the library-log attachment plus a
  /// screenshot.
  func test_stress_tappingPlayRepeatedlyOnOpen() {
    launch(route: .playerState)

    XCTAssertTrue(
      playPauseButton.waitForExistence(timeout: 3),
      "Play/pause button never appeared — view didn't mount"
    )

    // Five rapid taps — do NOT wait for state == playing. The race window
    // is between the `.task { try? player.play(url:) }` auto-play and the
    // user's fingers hammering togglePlayPause.
    for _ in 0..<5 {
      playPauseButton.tap()
    }

    // Give libVLC time to settle and either crash or stabilize.
    Thread.sleep(forTimeInterval: 3)

    XCTAssertTrue(
      playPauseButton.exists,
      "App crashed or the view tore down after rapid-tap-on-open"
    )
    XCTAssertTrue(
      playPauseButton.isHittable,
      "Play/pause button became non-interactive after rapid-tap-on-open"
    )

    assertNoLibraryErrors()
  }

  /// Hammer the play/pause button 25 times after playback has stabilized.
  /// libVLC's `libvlc_media_player_pause` is a toggle (see `Player.togglePlayPause`);
  /// rapid toggles have historically surfaced two upstream issues:
  ///
  /// 1. `libvlc stream filter error: reading while paused (buggy demux?)`
  ///    — the demuxer races with state flips.
  /// 2. The `pause_date == VLC_TICK_INVALID` assertion in the audio output
  ///    when a new play arrives before the previous pause has been
  ///    acknowledged internally.
  ///
  /// Test expectation: the app survives and the button stays interactive.
  func test_stress_rapidTogglePlayPause() {
    launch(route: .playerState)

    waitForLabel(stateLabel, equals: "playing", timeout: 10)

    for _ in 0..<25 {
      playPauseButton.tap()
    }

    XCTAssertTrue(playPauseButton.exists, "Play/pause button vanished after rapid toggling")
    XCTAssertTrue(playPauseButton.isHittable, "Play/pause button is no longer interactive")

    // State should stabilize to either `playing` or `paused` (with 25 taps
    // starting from `playing`, parity ends at `paused`). Allow 3s for the
    // last toggle to settle.
    Thread.sleep(forTimeInterval: 3)
    let finalState = stateLabel.label
    XCTAssertTrue(
      finalState == "playing" || finalState == "paused",
      "Expected state to settle at playing/paused after rapid taps, got '\(finalState)'"
    )

    assertNoLibraryErrors()
  }

  /// Relaunch the app a handful of times while media is playing. Each
  /// cycle creates and destroys a fresh `Player`; resident memory should
  /// plateau. Exercises Player init → auto-play → destructor under churn.
  func test_stress_presentDismissCycles() {
    launch(route: .playerState)
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

  /// Leave the player running for 30 seconds. State must stay at
  /// `playing` the whole time — no spontaneous drops to `paused`, `error`,
  /// or `stopped` without user input. Catches event-loop leaks and
  /// libVLC drift over sustained playback.
  func test_stress_longRunningStaysPlaying() {
    launch(route: .playerState)

    waitForLabel(stateLabel, equals: "playing", timeout: 10)

    let totalSeconds: TimeInterval = 30
    let pollInterval: TimeInterval = 5

    let started = Date()
    while Date().timeIntervalSince(started) < totalSeconds {
      Thread.sleep(forTimeInterval: pollInterval)
      XCTAssertEqual(
        stateLabel.label, "playing",
        "State drifted to '\(stateLabel.label)' at \(Int(Date().timeIntervalSince(started)))s of sustained playback"
      )
    }

    assertNoLibraryErrors()
  }

  /// Background/foreground the app mid-playback. On iOS with
  /// `AVAudioSession(.playback)` set, audio keeps running in background;
  /// video renders are suspended. State should remain coherent when the
  /// app re-enters foreground.
  func test_stress_backgroundForegroundPreservesState() {
    launch(route: .playerState)

    waitForLabel(stateLabel, equals: "playing", timeout: 10)

    for _ in 0..<2 {
      XCUIDevice.shared.press(.home)
      Thread.sleep(forTimeInterval: 2)
      app.activate()
      Thread.sleep(forTimeInterval: 2)

      XCTAssertTrue(stateLabel.exists, "State label gone after background round-trip")
      let afterState = stateLabel.label
      XCTAssertTrue(
        afterState == "playing" || afterState == "paused",
        "Unexpected state '\(afterState)' after backgrounding — expected playing or paused"
      )
    }

    assertNoLibraryErrors()
  }
}
