import XCTest

/// Downloads the host-pinned fixture bytes into the candidate app container,
/// then proves five local container/codec combinations advance native decode,
/// display, and independently captured pixels.
final class LocalPlaybackMatrixDeviceUITests: ShowcaseIOSTestCase {
  func test_localFileContainerCodecMatrixProducesMovingVideo() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Local playback qualification requires a physical Apple device")
    #else
    guard
      ProcessInfo.processInfo.environment["SWIFTVLC_LOCAL_PLAYBACK_DEVICE"] == "YES",
      let encodedBaseURL = ProcessInfo.processInfo.environment[
        "SWIFTVLC_LOCAL_PLAYBACK_BASE_URL_BASE64"
      ]
    else {
      throw XCTSkip("Set the candidate-bound local playback device environment")
    }

    var fixtureResults: [[String: Any]] = []
    for fixture in LocalPlaybackFixtureContract.videoFixtures {
      configureLaunch(
        route: .localFileMatrixValidation,
        fixture: fixture,
        encodedBaseURL: encodedBaseURL
      )
      launchDirectlyHandlingQualificationPermissions()
      // Complete XCTest launch/identity setup before consuming the short clip.
      let run = app.buttons[AccessibilityID.LocalFileMatrixValidation.runButton]
      XCTAssertTrue(run.waitForExistence(timeout: 10))
      run.tap()

      let state = element(AccessibilityID.LocalFileMatrixValidation.stateLabel)
      let result = element(AccessibilityID.LocalFileMatrixValidation.resultLabel)
      let error = element(AccessibilityID.LocalFileMatrixValidation.errorLabel)
      let video = element(AccessibilityID.LocalFileMatrixValidation.videoView)
      waitForLabel(state, equals: "playing", timeout: 30)
      waitForLabel(result, equals: "measuring", timeout: 30)
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))

      var frames: [VideoSurfaceCanonicalFrame] = []
      var captureSystemUptimes: [Double] = []
      for index in 0..<3 {
        try frames.append(captureInlineVideoSurfaceCanonicalFrame(video))
        captureSystemUptimes.append(ProcessInfo.processInfo.systemUptime)
        if index < 2 {
          RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
      }
      let visual = try XCTUnwrap(VideoSurfaceMotionEvidenceAnalyzer.analyze(frames))
      XCTAssertGreaterThanOrEqual(visual.changedPixelScore, 0.01)
      XCTAssertEqual(Set(visual.frameHashes).count, 3)

      waitForPrefix(result, prefix: "pass:", timeout: 30)
      XCTAssertFalse(error.exists, "Local fixture failed: \(error.label)")
      var raw = try decodeRawResult(result.label)
      let rawFixture = try XCTUnwrap(raw["fixture"] as? [String: Any])
      XCTAssertEqual(rawFixture["id"] as? String, fixture.id)
      XCTAssertEqual(raw["sourceScheme"] as? String, "file")
      raw["visualCapture"] = [
        "formatVersion": 1,
        "method": VideoSurfaceMotionEvidence.method,
        "encoding": "base64-rgb8-row-major",
        "frameWidthPixels": VideoSurfaceCanonicalFrame.width,
        "frameHeightPixels": VideoSurfaceCanonicalFrame.height,
        "channelCount": 3,
        "bytesPerFrame": VideoSurfaceCanonicalFrame.byteCount,
        "frameCount": 3,
        "captureSystemUptimeSeconds": captureSystemUptimes,
        "canonicalRGB8Base64": frames.map { Data($0.rgb).base64EncodedString() },
        "frameHashes": visual.frameHashes,
        "adjacentChangedPixelRatios": visual.adjacentChangedPixelRatios,
        "changedPixelScore": visual.changedPixelScore,
        "distinctFrameHashes": Set(visual.frameHashes).count
      ]
      fixtureResults.append(raw)
      app.terminate()
    }

    assertNoLibraryErrors()
    attachQualificationEvidence(
      [
        "matrixOutcome": "pass",
        "fixtureResults": fixtureResults,
        "libraryErrorCount": 0
      ],
      scenario: "local-file-matrix"
    )
    #endif
  }

  private func configureLaunch(
    route: UITestRoute,
    fixture: LocalPlaybackFixtureContract,
    encodedBaseURL: String
  ) {
    replaceLaunchArgument(LaunchArguments.route, with: route.rawValue)
    replaceLaunchArgument(LaunchArguments.localPlaybackBaseURLBase64, with: encodedBaseURL)
    replaceLaunchArgument(LaunchArguments.localPlaybackFixtureID, with: fixture.id)
  }

  private func decodeRawResult(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForPrefix(
    _ element: XCUIElement,
    prefix: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in element.exists && element.label.hasPrefix(prefix) }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func replaceLaunchArgument(_ key: String, with value: String) {
    while let index = app.launchArguments.firstIndex(of: key) {
      app.launchArguments.remove(at: index)
      if index < app.launchArguments.count {
        app.launchArguments.remove(at: index)
      }
    }
    app.launchArguments += [key, value]
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
