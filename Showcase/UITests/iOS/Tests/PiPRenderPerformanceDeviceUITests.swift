import XCTest

/// Drives the real SpringBoard PiP window while the candidate records its
/// direct-renderer and process metrics. Host-side Instruments traces are bound
/// to the attachment after xcresult export.
final class PiPRenderPerformanceDeviceUITests: ShowcaseIOSTestCase {
  func test_directPiPPerformanceRow() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("PiP performance qualifies only a physical iPhone")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_PERFORMANCE_DEVICE"] == "YES"
    else {
      throw XCTSkip("Set SWIFTVLC_PIP_PERFORMANCE_DEVICE=YES for candidate-bound hardware runs")
    }
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    let profile = ProcessInfo.processInfo.environment["SWIFTVLC_PIP_PERFORMANCE_PROFILE"]
      ?? "1080p60"
    let duration = max(
      1,
      Int(ProcessInfo.processInfo.environment["SWIFTVLC_PIP_PERFORMANCE_SECONDS"] ?? "900")
        ?? 900
    )
    let encodedURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SWIFTVLC_PIP_PERFORMANCE_URL_BASE64"]
    )
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.pipRenderPerformanceValidation.rawValue,
      LaunchArguments.pipPerformanceProfile, profile,
      LaunchArguments.pipPerformanceURLBase64, encodedURL,
      LaunchArguments.pipPerformanceDuration, String(duration)
    ]
    app.launch()
    app.tap()

    let possible = element(AccessibilityID.PiPRenderPerformanceValidation.possibleLabel)
    let active = element(AccessibilityID.PiPRenderPerformanceValidation.activeLabel)
    let result = element(AccessibilityID.PiPRenderPerformanceValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPRenderPerformanceValidation.runButton]
    let video = element(AccessibilityID.PiPRenderPerformanceValidation.videoView)
    let error = element(AccessibilityID.PiPRenderPerformanceValidation.errorLabel)
    waitForLabel(possible, equals: "yes", timeout: 30)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForLabel(active, equals: "yes", timeout: 30)
    assertRendersNonBlackFrame(video, timeout: 15)

    XCUIDevice.shared.press(.home)
    var region = try locateSystemPictureInPictureWindow()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let deadline = Date().addingTimeInterval(TimeInterval(duration))
    var resizeCount = 0
    while Date() < deadline.addingTimeInterval(-8) {
      springboard.coordinate(
        withNormalizedOffset: region.normalizedPoint(x: 0.5, y: 0.5)
      ).doubleTap()
      resizeCount += 1
      RunLoop.current.run(until: Date().addingTimeInterval(12))
      if resizeCount.isMultiple(of: 4) {
        region = try locateSystemPictureInPictureWindow(samples: 5, interval: 0.5)
      }
    }
    XCTAssertGreaterThanOrEqual(resizeCount, max(4, duration / 60))
    if let motionFailure = captureSystemPictureInPictureMotion() {
      XCTFail("PiP stopped rendering after resize/replacement cycles: \(motionFailure)")
    }

    app.activate()
    waitForPrefix(result, prefix: "pass:", timeout: 120)
    XCTAssertFalse(error.exists, "Performance row failed: \(error.label)")
    assertRendersNonBlackFrame(video, timeout: 15)

    let evidence = try decodeEvidence(result.label)
    let expectedScenario = profile == "4k60"
      ? "pip-render-performance-4k60"
      : "pip-render-performance-1080p60"
    XCTAssertEqual(evidence["profile"] as? String, profile)
    XCTAssertGreaterThanOrEqual(evidence["durationSeconds"] as? Int ?? 0, 900)
    XCTAssertGreaterThan(evidence["resizeCycles"] as? Int ?? 0, 1)
    XCTAssertGreaterThan(evidence["replacementCount"] as? Int ?? 0, 0)
    XCTAssertEqual(evidence["inlineQuality"] as? String, "preserved")
    XCTAssertEqual(evidence["effectiveWorkOutcome"] as? String, "reduced")
    XCTAssertEqual(evidence["boundedMemory"] as? Bool, true)
    XCTAssertEqual(evidence["boundedWork"] as? Bool, true)
    let metrics = try XCTUnwrap(evidence["metrics"] as? [String: Any])
    for required in ["cpu", "gpu", "rss", "energy", "thermal", "conversionCost", "frameDrops", "presentationRate"] {
      XCTAssertNotNil(metrics[required], "Missing metric \(required)")
    }
    attachQualificationEvidence(evidence, scenario: expectedScenario)
    #endif
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForPrefix(_ element: XCUIElement, prefix: String, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.label.hasPrefix(prefix) }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
