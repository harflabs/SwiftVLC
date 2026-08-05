import XCTest

/// Exercises every required CFR/VFR source while driving the real SpringBoard
/// PiP resize surface. The app records direct-renderer counters and transition
/// state; this test validates and attaches the candidate-bound evidence.
final class PiPCadenceDeviceUITests: ShowcaseIOSTestCase {
  func test_directPiPCadenceMatrix() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("The cadence matrix qualifies only a physical iPhone")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CADENCE_DEVICE"] == "YES"
    else {
      throw XCTSkip("Set SWIFTVLC_PIP_CADENCE_DEVICE=YES for candidate-bound hardware runs")
    }
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    let duration = max(
      1,
      Int(ProcessInfo.processInfo.environment["SWIFTVLC_CADENCE_SECONDS"] ?? "600")
        ?? 600
    )
    let encodedBaseURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CADENCE_BASE_URL_BASE64"]
    )
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.pipCadenceValidation.rawValue,
      LaunchArguments.pipCadenceBaseURLBase64, encodedBaseURL,
      LaunchArguments.pipCadenceDuration, String(duration)
    ]
    app.launch()
    app.tap()

    let possible = element(AccessibilityID.PiPCadenceValidation.possibleLabel)
    let active = element(AccessibilityID.PiPCadenceValidation.activeLabel)
    let result = element(AccessibilityID.PiPCadenceValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPCadenceValidation.runButton]
    let video = element(AccessibilityID.PiPCadenceValidation.videoView)
    let error = element(AccessibilityID.PiPCadenceValidation.errorLabel)
    waitForLabel(possible, equals: "yes", timeout: 30)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForLabel(active, equals: "yes", timeout: 60)
    assertRendersNonBlackFrame(video, timeout: 15)

    XCUIDevice.shared.press(.home)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var region = try locateSystemPictureInPictureWindow()
    let deadline = Date().addingTimeInterval(TimeInterval(duration))
    var resizeGestures = 0
    while Date() < deadline.addingTimeInterval(-8) {
      springboard.coordinate(
        withNormalizedOffset: region.normalizedPoint(x: 0.5, y: 0.5)
      ).doubleTap()
      resizeGestures += 1
      RunLoop.current.run(until: Date().addingTimeInterval(18))
      if resizeGestures.isMultiple(of: 4) {
        region = try locateSystemPictureInPictureWindow(samples: 5, interval: 0.5)
      }
    }
    XCTAssertGreaterThanOrEqual(resizeGestures, max(4, duration / 90))
    if let motionFailure = captureSystemPictureInPictureMotion() {
      XCTFail("PiP stopped rendering during cadence transitions: \(motionFailure)")
    }

    app.activate()
    waitForPrefix(result, prefix: "pass:", timeout: 180)
    XCTAssertFalse(error.exists, "Cadence row failed: \(error.label)")
    assertRendersNonBlackFrame(video, timeout: 15)

    let evidence = try decodeEvidence(result.label)
    let expectedRates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
    XCTAssertEqual(evidence["rates"] as? [Double], expectedRates)
    XCTAssertEqual(evidence["vfr"] as? Bool, true)
    XCTAssertGreaterThanOrEqual(evidence["durationSeconds"] as? Int ?? 0, 600)
    XCTAssertEqual(evidence["fabricatedDurationCount"] as? Int, 0)
    let metrics = try XCTUnwrap(evidence["presentationMetrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 9)
    for metric in metrics {
      XCTAssertGreaterThan(metric["deliveredFrames"] as? Int ?? 0, 0)
      XCTAssertGreaterThan(metric["presentationRate"] as? Double ?? 0, 0)
      XCTAssertLessThanOrEqual(metric["dropRate"] as? Double ?? 1, 0.10)
      XCTAssertEqual(metric["presentationCopyFailures"] as? Int, 0)
      XCTAssertEqual(metric["displayConsumeFailures"] as? Int, 0)
    }
    let transitions = try XCTUnwrap(evidence["transitionResults"] as? [String: Any])
    XCTAssertGreaterThanOrEqual(transitions["pauseResumeCycles"] as? Int ?? 0, 9)
    XCTAssertGreaterThanOrEqual(transitions["rateChanges"] as? Int ?? 0, 27)
    XCTAssertGreaterThanOrEqual(transitions["replacements"] as? Int ?? 0, 8)
    XCTAssertGreaterThan(transitions["resizeCycles"] as? Int ?? 0, 0)
    XCTAssertEqual(transitions["monotonicityViolations"] as? Int, 0)
    attachQualificationEvidence(evidence, scenario: "cadence-matrix")
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
