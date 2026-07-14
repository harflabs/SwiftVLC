import XCTest

final class TestStreamSettingsUITests: ShowcaseIOSTestCase {
  func test_streamURLStaysInSessionAndCanBeCleared() {
    launchAtRoot()
    openSettings()

    let clearButton = app.buttons[AccessibilityID.TestStream.clearButton]
    if clearButton.exists {
      clearButton.tap()
      openSettings()
    }

    let streamURL = "http://example.com/live/test.m3u8"
    let urlField = app.textFields[AccessibilityID.TestStream.urlField]
    XCTAssertTrue(urlField.waitForExistence(timeout: 5))
    urlField.tap()
    urlField.typeText(streamURL)

    let applyButton = app.buttons[AccessibilityID.TestStream.applyButton]
    XCTAssertTrue(applyButton.isEnabled)
    applyButton.tap()

    openSettings()
    XCTAssertEqual(
      app.textFields[AccessibilityID.TestStream.urlField].value as? String,
      streamURL
    )

    XCTAssertTrue(clearButton.waitForExistence(timeout: 5))
    clearButton.tap()
    XCTAssertTrue(
      app.buttons[AccessibilityID.TestStream.settingsLink].waitForExistence(timeout: 5)
    )

    openSettings()
    XCTAssertNotEqual(
      app.textFields[AccessibilityID.TestStream.urlField].value as? String,
      streamURL
    )

    let urlFieldAfterClear = app.textFields[AccessibilityID.TestStream.urlField]
    urlFieldAfterClear.tap()
    urlFieldAfterClear.typeText(streamURL)
    app.buttons[AccessibilityID.TestStream.applyButton].tap()

    app.terminate()
    app.launch()
    openSettings()
    XCTAssertNotEqual(
      app.textFields[AccessibilityID.TestStream.urlField].value as? String,
      streamURL
    )
    XCTAssertFalse(app.buttons[AccessibilityID.TestStream.clearButton].exists)
  }

  private func openSettings() {
    let settingsLink = app.buttons[AccessibilityID.TestStream.settingsLink]
    XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
    settingsLink.tap()
    XCTAssertTrue(
      app.textFields[AccessibilityID.TestStream.urlField].waitForExistence(timeout: 5)
    )
  }
}
