import XCTest

/// Discovery Renderers enumerates Chromecast/AirPlay renderers via
/// `RendererDiscoverer.availableServices()`. iOS simulator usually has
/// none; tests verify the enumeration path doesn't crash.
final class DiscoveryRenderersUITests: ShowcaseUITestCase {
  private var emptyServices: XCUIElement {
    app.staticTexts[AccessibilityID.DiscoveryRenderers.emptyServices]
  }

  func test_smoke_servicesSectionRendersState() {
    launch(route: .discoveryRenderers)

    let pickerID = AccessibilityID.DiscoveryRenderers.servicePicker
    let picker = app.descendants(matching: .any)[pickerID].firstMatch
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(
      picker.exists || emptyServices.waitForExistence(timeout: 5),
      "Service section rendered neither picker nor 'No renderer discoverers' — enumeration likely crashed"
    )

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .discoveryRenderers)
    Thread.sleep(forTimeInterval: 1)
    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        app.terminate()
        app.launch()
        Thread.sleep(forTimeInterval: 2)
      }
    }
    assertNoLibraryErrors()
  }
}
