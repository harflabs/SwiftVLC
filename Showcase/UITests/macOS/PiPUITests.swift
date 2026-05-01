import AVKit
import XCTest

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
