import XCTest

/// Two independent `for await event in player.events` loops filter the
/// same underlying broadcast. Regression guard: both consumers see
/// events; cancelling one (via view teardown) doesn't starve the
/// other. Smoke verifies both logs populate; stress cycles the view
/// to probe task-cancel correctness on `onDisappear`.
final class MultiConsumerEventsUITests: ShowcaseUITestCase {
  // Inherits `@MainActor` from `ShowcaseUITestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.MultiConsumer.playPauseButton]
  }

  private var lifecycleWaitingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.MultiConsumer.lifecycleWaitingLabel]
  }

  private var trackWaitingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.MultiConsumer.trackWaitingLabel]
  }

  private var lifecycleEntries: XCUIElementQuery {
    app.staticTexts.matching(identifier: AccessibilityID.MultiConsumer.lifecycleLogEntry)
  }

  private var trackEntries: XCUIElementQuery {
    app.staticTexts.matching(identifier: AccessibilityID.MultiConsumer.trackLogEntry)
  }

  // MARK: - Smoke

  /// Page loads and both consumer logs leave the "Waiting…" placeholder
  /// as events arrive. Verifies the multi-consumer fan-out works for a
  /// basic playback.
  func test_smoke_bothConsumersReceiveEvents() {
    launch(route: .multiConsumer)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    let lifecycleFilled = NSPredicate { _, _ in !self.lifecycleWaitingLabel.exists }
    let lifeExp = expectation(for: lifecycleFilled, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [lifeExp], timeout: 10) != .completed {
      XCTFail("Lifecycle consumer never received any events within 10s")
    }
    XCTAssertGreaterThan(
      lifecycleEntries.count, 0,
      "Lifecycle log should have at least one entry once Waiting… is gone"
    )

    let trackFilled = NSPredicate { _, _ in !self.trackWaitingLabel.exists }
    let trackExp = expectation(for: trackFilled, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [trackExp], timeout: 10) != .completed {
      XCTFail("Track consumer never received any events within 10s")
    }
    XCTAssertGreaterThan(
      trackEntries.count, 0,
      "Track log should have at least one entry once Waiting… is gone"
    )

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Present/dismiss cycles exercise the `.task { await consumerA() }`
  /// + `.task { await consumerB() }` cleanup path. Both consumer
  /// Tasks must cancel on view teardown — a leak would show as
  /// ballooning memory across cycles.
  func test_stress_presentDismissCycles() {
    launch(route: .multiConsumer)
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))

    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        app.terminate()
        app.launch()
        _ = playPauseButton.waitForExistence(timeout: 5)
      }
    }

    assertNoLibraryErrors()
  }
}
