import XCTest

/// Proves six local audio codecs reach native decode and the real audio-output
/// buffer stage. Labels alone cannot satisfy this row: the attachment retains
/// the raw media clock and libVLC statistics sampled by the candidate.
final class AudioOnlyPlaybackDeviceUITests: ShowcaseIOSTestCase {
  func test_audioOnlyCodecMatrixAdvancesNativeOutput() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Audio-only qualification requires a physical Apple device")
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
    for fixture in LocalPlaybackFixtureContract.audioFixtures {
      configureLaunch(fixture: fixture, encodedBaseURL: encodedBaseURL)
      launchDirectlyHandlingQualificationPermissions()
      let run = app.buttons[AccessibilityID.AudioOnlyPlaybackValidation.runButton]
      XCTAssertTrue(run.waitForExistence(timeout: 10))
      run.tap()

      let result = element(AccessibilityID.AudioOnlyPlaybackValidation.resultLabel)
      let error = element(AccessibilityID.AudioOnlyPlaybackValidation.errorLabel)
      // The retained native counter window proves playback even if XCTest
      // observes this result after EOF; a transient state label cannot do so.
      waitForPrefix(result, prefix: "pass:", timeout: 30)
      XCTAssertFalse(error.exists, "Audio-only fixture failed: \(error.label)")
      let raw = try decodeRawResult(result.label)
      let rawFixture = try XCTUnwrap(raw["fixture"] as? [String: Any])
      XCTAssertEqual(rawFixture["id"] as? String, fixture.id)
      XCTAssertEqual(raw["sourceScheme"] as? String, "file")
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
      scenario: "audio-only-playback"
    )
    #endif
  }

  private func configureLaunch(
    fixture: LocalPlaybackFixtureContract,
    encodedBaseURL: String
  ) {
    replaceLaunchArgument(
      LaunchArguments.route,
      with: UITestRoute.audioOnlyPlaybackValidation.rawValue
    )
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
