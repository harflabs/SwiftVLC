import XCTest

/// PlaylistQueue wraps Player in MediaListPlayer. Tests the queue
/// construction path and the present/dismiss lifecycle.
final class PlaylistQueueUITests: ShowcaseIOSTestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.PlaylistQueue.playPauseButton]
  }

  func test_smoke_queueLoadsAndPlays() {
    launch(route: .playlistQueue)
    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .playlistQueue)
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

final class MusicPlayerUITests: ShowcaseIOSTestCase {
  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.MusicPlayer.playPauseButton]
  }

  private var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.MusicPlayer.currentTime]
  }

  private var dismissButton: XCUIElement {
    app.buttons[AccessibilityID.MusicPlayer.dismissButton]
  }

  func test_switchingTracksKeepsTransportStateAndDoesNotCrash() throws {
    let fixtures = try makeDistinctMusicFixtures()
    app.launchArguments += [
      LaunchArguments.musicFixtureURLs,
      fixtures.map(\.path).joined(separator: "|")
    ]
    launch(route: .musicPlayer)

    for title in ["Showcase Reel", "Big Buck Bunny", "HLS test stream", "Showcase Reel"] {
      let songButton = app.buttons[AccessibilityID.MusicPlayer.songButton(title)]
      XCTAssertTrue(songButton.waitForExistence(timeout: 5), "Missing song row: \(title)")
      songButton.tap()

      XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
      waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
      XCTAssertTrue(currentTimeLabel.waitForExistence(timeout: 5))
      waitForLabel(currentTimeLabel, notEqual: "0:00", timeout: 10)
      XCTAssertEqual(playPauseButton.label, "Pause")

      dismissButton.tap()
    }

    assertNoLibraryErrors()
  }

  private func makeDistinctMusicFixtures() throws -> [URL] {
    let bundle = Bundle(for: Self.self)
    let source = try XCTUnwrap(
      bundle.url(forResource: "test", withExtension: "mp4", subdirectory: "Fixtures")
        ?? bundle.url(forResource: "test", withExtension: "mp4")
    )
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("music-player-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try ["one", "two", "three"].map { name in
      let destination = directory.appendingPathComponent("\(name).mp4")
      try FileManager.default.copyItem(at: source, to: destination)
      return destination
    }
  }
}
