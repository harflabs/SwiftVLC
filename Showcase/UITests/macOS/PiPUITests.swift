import AVKit
import XCTest

private enum MacDeinterlaceAccessibilityID {
  static let statePicker = "macos.deinterlace.state.picker"
  static let stateOffSegment = "macos.deinterlace.state.off"
  static let stateOnSegment = "macos.deinterlace.state.on"
  static let stateValue = "macos.deinterlace.state.value"

  static func stateSegment(_ title: String) -> String {
    switch title {
    case "Off": stateOffSegment
    case "On": stateOnSegment
    default: title
    }
  }
}

@MainActor
final class MacOSPiPUITests: XCTestCase {
  func test_startPiPButtonStartsPiPWhenSystemSupportsPiP() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("macOS Picture in Picture is not supported in this environment.")
    }

    let app = XCUIApplication()
    app.launchArguments += [
      "-UITestMode", "YES",
      "-UITestRoute", "PiP",
      "-UITestFixtureURL", Self.fixtureURL.path
    ]
    app.launch()
    defer { app.terminate() }

    let toggleButton = app.buttons["macos.pip.toggle"]
    XCTAssertTrue(toggleButton.waitForExistence(timeout: 10), "Start PiP button never appeared.")

    let enabled = NSPredicate(format: "isEnabled == true")
    expectation(for: enabled, evaluatedWith: toggleButton)
    waitForExpectations(timeout: 20)

    toggleButton.click()

    let activeValue = app.staticTexts["macos.pip.active.value"]
    XCTAssertTrue(activeValue.waitForExistence(timeout: 5), "PiP active status never appeared.")

    let active = NSPredicate(format: "label == %@", "Yes")
    expectation(for: active, evaluatedWith: activeValue)
    waitForExpectations(timeout: 10)
  }

  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("iOS/Fixtures/test.mp4")
  }
}

@MainActor
final class MacOSDeinterlacingUITests: XCTestCase {
  func test_filterStateCanToggleOnThenOffWithoutCrashing() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-UITestMode", "YES",
      "-UITestRoute", "Deinterlacing",
      "-UITestFixtureURL", Self.fixtureURL.path
    ]
    app.launch()
    defer { app.terminate() }

    let stateValue = app.staticTexts[MacDeinterlaceAccessibilityID.stateValue]
    XCTAssertTrue(stateValue.waitForExistence(timeout: 10), "Deinterlace state never appeared.")

    clickDeinterlaceState("On", in: app)
    waitForText(stateValue, equals: "On", timeout: 5)

    clickDeinterlaceState("Off", in: app)
    waitForText(stateValue, equals: "Off", timeout: 5)
  }

  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("iOS/Fixtures/test.mp4")
  }

  private func clickDeinterlaceState(
    _ title: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let segment = app.descendants(matching: .any)[MacDeinterlaceAccessibilityID.stateSegment(title)]
    if segment.waitForExistence(timeout: 5) {
      segment.click()
      return
    }

    let picker = app.segmentedControls[MacDeinterlaceAccessibilityID.statePicker]
    if picker.waitForExistence(timeout: 2) {
      let xOffset: CGFloat = title == "Off" ? 0.5 : 0.83
      picker.coordinate(withNormalizedOffset: CGVector(dx: xOffset, dy: 0.5)).click()
      return
    }

    let fallback = app.buttons[title]
    if fallback.waitForExistence(timeout: 2) {
      fallback.click()
      return
    }

    XCTFail("Missing deinterlace segment '\(title)'", file: file, line: line)
  }

  private func waitForText(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in self.accessibleText(of: element) == expected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected text '\(expected)' but found '\(accessibleText(of: element))' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  private func accessibleText(of element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    return element.label
  }
}

@MainActor
final class MacOSMusicPlayerUITests: XCTestCase {
  func test_switchingTracksKeepsTransportStateAndDoesNotCrash() throws {
    let fixtures = try makeDistinctMusicFixtures()
    let app = XCUIApplication()
    app.launchArguments += [
      "-UITestMode", "YES",
      "-UITestRoute", "MusicPlayer",
      "-UITestMusicFixtureURLs", fixtures.map(\.path).joined(separator: "|")
    ]
    app.launch()
    defer { app.terminate() }

    let playPauseButton = app.buttons["music.playPause"]
    let timeValue = app.staticTexts["music.currentTime"]
    XCTAssertTrue(timeValue.waitForExistence(timeout: 10), "Music player time never appeared.")
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 10), "Music player transport never appeared.")

    for title in ["Demo reel", "Big Buck Bunny", "HLS Stream", "Demo reel"] {
      let songTitle = app.staticTexts[title]
      XCTAssertTrue(songTitle.waitForExistence(timeout: 5), "Missing song row: \(title)")
      songTitle.click()

      waitForText(playPauseButton, equals: "Pause", timeout: 10)
      waitForText(timeValue, notEqual: "0:00", timeout: 10)
      XCTAssertEqual(accessibleText(of: playPauseButton), "Pause")
    }
  }

  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("iOS/Fixtures/test.mp4")
  }

  private func makeDistinctMusicFixtures() throws -> [URL] {
    let source = Self.fixtureURL
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("music-player-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try ["one", "two", "three"].map { name in
      let destination = directory.appendingPathComponent("\(name).mp4")
      try FileManager.default.copyItem(at: source, to: destination)
      return destination
    }
  }

  private func waitForText(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in self.accessibleText(of: element) == expected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected text '\(expected)' but found '\(accessibleText(of: element))' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  private func waitForText(
    _ element: XCUIElement,
    notEqual unexpected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in self.accessibleText(of: element) != unexpected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Text still '\(unexpected)' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  private func accessibleText(of element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    return element.label
  }
}
