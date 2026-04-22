import XCTest

/// Audio Tracks surfaces `player.audioTracks` and drives track selection
/// via a SwiftUI Picker. Changing tracks mid-playback reconfigures
/// libVLC's audio output — the subsystem that has surfaced the most
/// bugs so far. The local fixture has a single audio stream; the suite
/// verifies the happy path (tracks load, picker renders) and stress
/// patterns (rapid re-launches) rather than exhaustive track-switching,
/// which would need a multi-track fixture.
final class AudioTracksUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AudioTracks.playPauseButton]
  }

  private var loadingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.AudioTracks.loadingLabel]
  }

  private var trackPicker: XCUIElement {
    app.otherElements[AccessibilityID.AudioTracks.trackPicker]
  }

  /// The picker can render in XCUITest as any of several element types
  /// depending on SwiftUI's chosen style — scan the likely families so
  /// the test passes regardless of platform styling.
  private var trackPickerAnyElement: XCUIElement {
    let id = AccessibilityID.AudioTracks.trackPicker
    return app.descendants(matching: .any)[id].firstMatch
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, and the audio track list populates
  /// (the "Loading…" placeholder is replaced by the picker within 10 s).
  func test_smoke_audioTracksPopulate() {
    launch(route: .audioTracks)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    // Loading placeholder should disappear once player.audioTracks is
    // non-empty.
    let loaded = NSPredicate { _, _ in !self.loadingLabel.exists }
    let exp = expectation(for: loaded, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: 10) != .completed {
      XCTFail("audioTracks never populated — 'Loading…' placeholder still visible after 10s")
    }
    XCTAssertTrue(
      trackPickerAnyElement.exists,
      "Track picker not in accessibility tree after tracks loaded"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Re-launch the app with the same media several times. Each cycle
  /// creates a fresh Player + parses tracks, so leak-prone paths
  /// (track list memory, VLCInstance reuse) are exercised.
  func test_stress_presentDismissCycles() {
    launch(route: .audioTracks)
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
