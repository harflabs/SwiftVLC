import XCTest

/// Discovery LAN enumerates network discoverers via
/// `MediaDiscoverer.availableServices(category: .lan)`. On iOS
/// simulator the list is typically empty or minimal; tests verify the
/// enumeration path doesn't crash and the UI renders a sensible state.
final class DiscoveryLANUITests: ShowcaseIOSTestCase {
  private var emptyServices: XCUIElement {
    app.staticTexts[AccessibilityID.DiscoveryLAN.emptyServices]
  }

  func test_smoke_servicesSectionRendersState() {
    launch(route: .discoveryLAN)

    let pickerID = AccessibilityID.DiscoveryLAN.servicePicker
    let picker = app.descendants(matching: .any)[pickerID].firstMatch
    // Wait briefly for the task to populate.
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(
      picker.exists || emptyServices.waitForExistence(timeout: 5),
      "Service section rendered neither picker nor 'No LAN discoverers' — enumeration likely crashed"
    )

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .discoveryLAN)
    // No player, so wait for any known identifier to confirm mount.
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
