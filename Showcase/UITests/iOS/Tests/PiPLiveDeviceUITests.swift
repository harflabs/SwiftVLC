import XCTest

/// End-to-end proof for indefinite MPEG-TS PiP. This test intentionally skips
/// unless the caller supplies `SWIFTVLC_PIP_LIVE_URL`; CI and simulator lanes
/// do not pretend to validate system PiP.
final class PiPLiveDeviceUITests: ShowcaseIOSTestCase {
  func test_nativeLiveMPEGTSRendersMovingFramesInSystemPiP() throws {
    try runLivePictureInPicture(renderingPath: "native")
  }

  func test_directLiveMPEGTSRendersMovingFramesInSystemPiP() throws {
    try runLivePictureInPicture(renderingPath: "direct")
  }

  private func runLivePictureInPicture(renderingPath: String) throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard
      let rawURL = ProcessInfo.processInfo.environment["SWIFTVLC_PIP_LIVE_URL"],
      let liveURL = URL(string: rawURL)
    else {
      throw XCTSkip("Set SWIFTVLC_PIP_LIVE_URL to an indefinite MPEG-TS stream")
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }

    app.launchArguments += [LaunchArguments.pipLiveURL, liveURL.absoluteString]
    app.launchArguments += [LaunchArguments.pipRenderingPath, renderingPath]
    launch(route: .pipLiveValidation)
    // UI interruption monitors run when the test sends an interaction after
    // presentation. A harmless tap lets a fresh install accept local-network
    // access before playback's opening timeout expires.
    app.tap()

    // Xcode 26.6 can expose SwiftUI Text with an identifier as either
    // StaticText or Other on a physical iPad. Query by identifier across all
    // accessibility types so the assertion measures state, not AX bridging.
    let state = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.stateLabel]
    let duration = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.durationLabel]
    let displayedPictures = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.displayedPicturesLabel
    ]
    let possible = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.possibleLabel]
    let active = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.activeLabel]
    let playbackError = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.errorLabel]
    let toggle = app.buttons[AccessibilityID.PiPLiveValidation.toggleButton]
    let video = app.otherElements[AccessibilityID.PiPLiveValidation.videoView]

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(duration, equals: "unknown", timeout: 5)
    waitForLabel(possible, equals: "yes", timeout: 15)
    let displayedBeforePiP = waitForIntegerLabel(
      displayedPictures,
      greaterThan: 0,
      timeout: 10
    )
    assertRendersNonBlackFrame(video, timeout: 10)

    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertTrue(toggle.isEnabled)
    for cycle in 0..<3 {
      toggle.tap()
      waitForLabel(active, equals: "yes", timeout: 10)
      if cycle < 2 {
        toggle.tap()
        waitForLabel(active, equals: "no", timeout: 10)
      }
    }

    if renderingPath == "native" {
      // Exercises VLC's placement/crop control callbacks while its PiP
      // controller is active, then returns to a deterministic orientation for
      // the system-window screenshot comparison below.
      XCUIDevice.shared.orientation = .landscapeRight
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      waitForLabel(active, equals: "yes", timeout: 5)
      XCUIDevice.shared.orientation = .portrait
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      waitForLabel(active, equals: "yes", timeout: 5)
    }

    XCUIDevice.shared.press(.home)
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    assertSystemPictureInPictureRendersMotion()

    app.activate()
    waitForLabel(state, equals: "playing", timeout: 10)
    waitForLabel(duration, equals: "unknown", timeout: 5)
    _ = waitForIntegerLabel(
      displayedPictures,
      greaterThan: displayedBeforePiP,
      timeout: 10
    )
    XCTAssertFalse(
      playbackError.exists,
      "Validation surface reported an asynchronous playback error: \(playbackError.label)"
    )
    #endif
  }
}
