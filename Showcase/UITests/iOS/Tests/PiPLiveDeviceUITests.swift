import XCTest

/// End-to-end proof for indefinite MPEG-TS PiP. This test intentionally skips
/// unless the caller supplies `SWIFTVLC_PIP_LIVE_URL`; CI and simulator lanes
/// do not pretend to validate system PiP.
final class PiPLiveDeviceUITests: ShowcaseIOSTestCase {
  func test_nativeLiveMPEGTSRendersMovingFramesInSystemPiP() throws {
    _ = try runLivePictureInPicture(renderingPath: "native")
  }

  func test_directLiveMPEGTSRendersMovingFramesInSystemPiP() throws {
    _ = try runLivePictureInPicture(renderingPath: "direct")
  }

  func test_liveMediaQualificationAcrossNativeAndDirectBackends() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    let native = try runLivePictureInPicture(renderingPath: "native")
    let direct = try runLivePictureInPicture(renderingPath: "direct")
    XCTAssertEqual(native.playbackRange, "unbounded")
    XCTAssertEqual(direct.playbackRange, "unbounded")
    XCTAssertTrue(native.linearPlayback)
    XCTAssertTrue(direct.linearPlayback)
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "live-media",
        "events": [
          "started": true,
          "unexpectedStopCount": native.unexpectedStopCount + direct.unexpectedStopCount,
          "order": "pass"
        ],
        "playbackRange": "unbounded",
        "linearPlayback": true,
        "backendResults": [
          "native": "pass",
          "direct": "pass"
        ],
        "systemPiPMotion": [
          "native": "pass",
          "direct": "pass"
        ]
      ],
      scenario: "live-media"
    )
    #endif
  }

  func test_backgroundAudioQualificationWhileAppIsBackgrounded() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Background audio qualification requires a physical iOS device")
    #else
    let evidence = try runLivePictureInPicture(renderingPath: "native")
    XCTAssertGreaterThan(
      evidence.playedAudioBuffersAfterBackground,
      evidence.playedAudioBuffersBeforeBackground
    )
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "background-audio",
        "events": [
          "started": true,
          "unexpectedStopCount": evidence.unexpectedStopCount,
          "order": "pass"
        ],
        "audioContinuity": "pass",
        "backgroundApplicationState": true,
        "measurementMethod": "libvlc-played-audio-buffers",
        "measurements": [
          "playedAudioBuffersBeforeBackground": evidence.playedAudioBuffersBeforeBackground,
          "playedAudioBuffersAfterBackground": evidence.playedAudioBuffersAfterBackground
        ]
      ],
      scenario: "background-audio"
    )
    #endif
  }

  private struct LiveRunEvidence {
    let playbackRange: String
    let linearPlayback: Bool
    let unexpectedStopCount: Int
    let playedAudioBuffersBeforeBackground: Int
    let playedAudioBuffersAfterBackground: Int
  }

  private struct BackgroundAudioObservation {
    let before: Int
    let after: Int
  }

  private func runLivePictureInPicture(renderingPath: String) throws -> LiveRunEvidence {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard
      let encodedURL = ProcessInfo.processInfo.environment["SWIFTVLC_PIP_LIVE_URL_BASE64"],
      let data = Data(base64Encoded: encodedURL),
      let rawURL = String(data: data, encoding: .utf8),
      let liveURL = URL(string: rawURL)
    else {
      throw XCTSkip("Set SWIFTVLC_PIP_LIVE_URL_BASE64 to an encoded indefinite MPEG-TS stream")
    }

    let encodedLiveURL = Data(liveURL.absoluteString.utf8).base64EncodedString()
    replaceLaunchArgument(LaunchArguments.pipLiveURLBase64, with: encodedLiveURL)
    app.launchEnvironment[LaunchArguments.pipLiveURLEnvironment] = encodedLiveURL
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: renderingPath)
    removeLaunchArgument(LaunchArguments.route)
    launch(route: .pipLiveValidation)

    // Xcode 26.6 can expose SwiftUI Text with an identifier as either
    // StaticText or Other on a physical iPad. Query by identifier across all
    // accessibility types so the assertion measures state, not AX bridging.
    let state = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.stateLabel]
    let duration = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.durationLabel]
    let displayedPictures = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.displayedPicturesLabel
    ]
    let playedAudioBuffers = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.playedAudioBuffersLabel
    ]
    let backgroundAudioObservation = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.backgroundAudioObservationLabel
    ]
    let possible = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.possibleLabel]
    let active = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.activeLabel]
    let linearPlayback = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.linearPlaybackLabel
    ]
    let playbackRange = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.playbackRangeLabel
    ]
    let lifecycleEvents = app.descendants(matching: .any)[
      AccessibilityID.PiPLiveValidation.lifecycleEventsLabel
    ]
    let playbackError = app.descendants(matching: .any)[AccessibilityID.PiPLiveValidation.errorLabel]
    let toggle = app.buttons[AccessibilityID.PiPLiveValidation.toggleButton]
    let captureDiagnostics = app.buttons[
      AccessibilityID.PiPLiveValidation.captureDiagnosticsButton
    ]
    let video = app.otherElements[AccessibilityID.PiPLiveValidation.videoView]

    waitForAccessibilityValue(state, equals: "playing", timeout: 20)
    waitForAccessibilityValue(duration, equals: "unknown", timeout: 5)
    assertRendersNonBlackFrame(video, timeout: 10)

    revealMeasurement(displayedPictures, swiping: .up)
    let displayedBeforePiP = waitForIntegerAccessibilityValue(
      displayedPictures,
      greaterThan: 0,
      timeout: 10
    )
    revealMeasurement(playedAudioBuffers, swiping: .up)
    _ = waitForIntegerAccessibilityValue(playedAudioBuffers, greaterThan: 0, timeout: 10)
    revealMeasurement(possible, swiping: .up)
    waitForAccessibilityValue(possible, equals: "yes", timeout: 15)
    revealMeasurement(linearPlayback, swiping: .up)
    waitForAccessibilityValue(linearPlayback, equals: "yes", timeout: 10)
    let observedLinearPlayback = accessibilityValue(of: linearPlayback)
    revealMeasurement(playbackRange, swiping: .up)
    waitForAccessibilityValue(playbackRange, equals: "unbounded", timeout: 10)
    let observedPlaybackRange = accessibilityValue(of: playbackRange)
    if renderingPath == "direct" {
      attachDirectRendererDiagnostics(
        captureDiagnostics,
        name: "inline-before-pip"
      )
    }

    reveal(toggle, swiping: .up)
    XCTAssertTrue(toggle.isEnabled)
    for cycle in 0..<3 {
      toggle.tap()
      revealMeasurement(active, swiping: .down)
      waitForAccessibilityValue(active, equals: "yes", timeout: 10)
      revealMeasurement(lifecycleEvents, swiping: .up)
      waitForLifecycleEvent(
        "didStart",
        count: cycle + 1,
        in: lifecycleEvents,
        timeout: 10
      )
      if renderingPath == "direct" {
        attachDirectRendererDiagnostics(
          captureDiagnostics,
          name: "cycle-\(cycle + 1)-started"
        )
      }
      if cycle < 2 {
        reveal(toggle, swiping: .up)
        toggle.tap()
        revealMeasurement(active, swiping: .down)
        waitForAccessibilityValue(active, equals: "no", timeout: 10)
        revealMeasurement(lifecycleEvents, swiping: .up)
        waitForLifecycleEvent(
          "didStop:programmatic",
          count: cycle + 1,
          in: lifecycleEvents,
          timeout: 10
        )
        if renderingPath == "direct" {
          attachDirectRendererDiagnostics(
            captureDiagnostics,
            name: "cycle-\(cycle + 1)-stopped"
          )
        }
        reveal(toggle, swiping: .up)
      }
    }

    if renderingPath == "native" {
      // Exercises VLC's placement/crop control callbacks while its PiP
      // controller is active, then returns to a deterministic orientation for
      // the system-window screenshot comparison below.
      XCUIDevice.shared.orientation = .landscapeRight
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      revealMeasurement(active, swiping: .down)
      waitForAccessibilityValue(active, equals: "yes", timeout: 5)
      XCUIDevice.shared.orientation = .portrait
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      revealMeasurement(active, swiping: .down)
      waitForAccessibilityValue(active, equals: "yes", timeout: 5)
    }

    XCUIDevice.shared.press(.home)
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let visualFailure = captureSystemPictureInPictureMotion()

    app.activate()
    revealMeasurement(state, swiping: .down)
    waitForAccessibilityValue(state, equals: "playing", timeout: 10)
    revealMeasurement(duration, swiping: .up)
    waitForAccessibilityValue(duration, equals: "unknown", timeout: 5)
    revealMeasurement(displayedPictures, swiping: .up)
    _ = waitForIntegerAccessibilityValue(
      displayedPictures,
      greaterThan: displayedBeforePiP,
      timeout: 10
    )
    revealMeasurement(backgroundAudioObservation, swiping: .up)
    let audioObservation = waitForBackgroundAudioObservation(
      backgroundAudioObservation,
      timeout: 10
    )
    XCTAssertGreaterThan(
      audioObservation.after,
      audioObservation.before,
      "Native audio output did not play buffers during the background interval"
    )
    revealMeasurement(active, swiping: .up)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    if renderingPath == "direct" {
      attachDirectRendererDiagnostics(
        captureDiagnostics,
        name: "after-background"
      )
    }
    revealMeasurement(lifecycleEvents, swiping: .up)
    reveal(toggle, swiping: .up)
    XCTAssertFalse(
      playbackError.exists,
      "Validation surface reported an asynchronous playback error: \(playbackError.label)"
    )
    if let visualFailure {
      XCTFail(visualFailure)
    }
    let events = accessibilityValue(of: lifecycleEvents).split(separator: "|").map(String.init)
    XCTAssertTrue(
      lifecycleOrderIsValid(events),
      "PiP lifecycle events were missing or out of order: \(events)"
    )
    let unexpectedStops = events.filter {
      $0.hasPrefix("didStop:") && $0 != "didStop:programmatic"
    }
    XCTAssertTrue(
      unexpectedStops.isEmpty,
      "Live PiP stopped unexpectedly: \(unexpectedStops)"
    )
    assertNoLibraryErrors()
    return LiveRunEvidence(
      playbackRange: observedPlaybackRange,
      linearPlayback: observedLinearPlayback == "yes",
      unexpectedStopCount: unexpectedStops.count,
      playedAudioBuffersBeforeBackground: audioObservation.before,
      playedAudioBuffersAfterBackground: audioObservation.after
    )
    #endif
  }

  private func waitForLifecycleEvent(
    _ event: String,
    count: Int,
    in element: XCUIElement,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      self.accessibilityValue(of: element)
        .split(separator: "|")
        .count(where: { $0 == Substring(event) }) == count
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(count) '\(event)' lifecycle event(s), got "
        + "\(accessibilityValue(of: element))"
    )
  }

  private func waitForBackgroundAudioObservation(
    _ element: XCUIElement,
    timeout: TimeInterval
  ) -> BackgroundAudioObservation {
    let predicate = NSPredicate { _, _ in
      self.parseBackgroundAudioObservation(self.accessibilityValue(of: element))
        .map { $0.after > $0.before } == true
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    let value = accessibilityValue(of: element)
    guard let observation = parseBackgroundAudioObservation(value) else {
      XCTFail("Background audio probe did not publish two counters: \(value)")
      return BackgroundAudioObservation(before: Int.max, after: Int.min)
    }
    return observation
  }

  private func parseBackgroundAudioObservation(_ value: String) -> BackgroundAudioObservation? {
    let components = value.split(separator: ":")
    guard
      components.count == 2,
      let before = Int(components[0]),
      let after = Int(components[1])
    else { return nil }
    return BackgroundAudioObservation(before: before, after: after)
  }

  private func reveal(
    _ element: XCUIElement,
    swiping direction: ShowcaseScrollDirection
  ) {
    for _ in 0..<10 where !element.isHittable {
      switch direction {
      case .up: app.swipeUp()
      case .down: app.swipeDown()
      }
    }
    if !element.isHittable {
      for _ in 0..<20 where !element.isHittable {
        direction.opposite.perform(in: app)
      }
    }
    XCTAssertTrue(element.isHittable, "Could not reveal \(element)")
  }

  private func replaceLaunchArgument(_ name: String, with value: String) {
    removeLaunchArgument(name)
    app.launchArguments += [name, value]
  }

  private func removeLaunchArgument(_ name: String) {
    while let index = app.launchArguments.firstIndex(of: name) {
      app.launchArguments.remove(at: index)
      if index < app.launchArguments.endIndex {
        app.launchArguments.remove(at: index)
      }
    }
  }

  private func lifecycleOrderIsValid(_ events: [String]) -> Bool {
    var state = "idle"
    var startCount = 0
    var stopCount = 0
    for event in events {
      switch event {
      case "willStart" where state == "idle":
        state = "starting"
      case "didStart" where state == "starting":
        state = "active"
        startCount += 1
      case "willStop:programmatic" where state == "active":
        state = "stopping"
      case "didStop:programmatic" where state == "stopping":
        state = "idle"
        stopCount += 1
      default:
        return false
      }
    }
    return state == "active" && startCount == 3 && stopCount == 2
  }

  private func attachDirectRendererDiagnostics(
    _ diagnosticsElement: XCUIElement,
    name: String
  ) {
    XCTAssertTrue(diagnosticsElement.waitForExistence(timeout: 5))
    let previous = accessibilityValue(of: diagnosticsElement)
    XCTAssertTrue(diagnosticsElement.isHittable, "Diagnostics control is not hittable")
    diagnosticsElement.tap()
    let predicate = NSPredicate { _, _ in
      let value = self.accessibilityValue(of: diagnosticsElement)
      return value.hasPrefix("capture=") && value != previous
    }
    let updated = XCTNSPredicateExpectation(predicate: predicate, object: diagnosticsElement)
    XCTAssertEqual(
      XCTWaiter.wait(for: [updated], timeout: 2),
      .completed,
      "Diagnostics capture did not publish a new snapshot"
    )
    let current = accessibilityValue(of: diagnosticsElement)
    let attachment = XCTAttachment(string: current)
    attachment.name = "direct-renderer-diagnostics-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
