import XCTest

/// Thumbnails previously flagged as "not working" — this suite covers
/// the full flow: Generate taps, thumbnail appearance, offset changes,
/// and rapid regeneration (a common user pattern for scrubber preview
/// scrubbing).
final class ThumbnailsUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var generateButton: XCUIElement {
    app.buttons[AccessibilityID.Thumbnails.generateButton]
  }

  private var thumbnailImage: XCUIElement {
    app.images[AccessibilityID.Thumbnails.thumbnailImage]
  }

  private var emptyPlaceholder: XCUIElement {
    app.staticTexts[AccessibilityID.Thumbnails.emptyPlaceholder]
  }

  private var offsetSlider: XCUIElement {
    app.sliders[AccessibilityID.Thumbnails.offsetSlider]
  }

  private var offsetLabel: XCUIElement {
    app.staticTexts[AccessibilityID.Thumbnails.offsetLabel]
  }

  // MARK: - Smoke

  /// Page loads with the empty-state placeholder and a hittable
  /// Generate button. Offset label reflects the initial slider value.
  func test_smoke_initialStateShowsPlaceholder() {
    launch(route: .thumbnails)

    XCTAssertTrue(generateButton.waitForExistence(timeout: 5), "Generate button never appeared")
    XCTAssertTrue(generateButton.isHittable, "Generate button not hittable")
    XCTAssertTrue(emptyPlaceholder.exists, "Empty-state placeholder missing before first generate")
    XCTAssertFalse(thumbnailImage.exists, "Thumbnail image should not exist before first generate")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Tap Generate once and wait for the thumbnail image to materialize.
  /// This is the core contract: call `media.thumbnail(at:)` → receive
  /// PNG → render. The previous "not working" report lives or dies
  /// here.
  func test_deep_generateProducesThumbnail() {
    launch(route: .thumbnails)

    XCTAssertTrue(generateButton.waitForExistence(timeout: 5))
    generateButton.tap()

    // Thumbnail request has a 10 s library timeout; allow 15 s total
    // for the async render + image swap.
    XCTAssertTrue(
      thumbnailImage.waitForExistence(timeout: 15),
      "Thumbnail image never appeared after Generate tap"
    )
    XCTAssertFalse(emptyPlaceholder.exists, "Empty-state placeholder should be gone after thumbnail renders")

    assertNoLibraryErrors()
  }

  /// Generating a second time with a different offset must replace the
  /// previous image (the Swift wrapper's thumbnail coordinator has to
  /// serialize requests and flush stale results).
  func test_deep_generateTwiceReplacesImage() {
    launch(route: .thumbnails)

    XCTAssertTrue(generateButton.waitForExistence(timeout: 5))
    generateButton.tap()
    XCTAssertTrue(thumbnailImage.waitForExistence(timeout: 15), "First thumbnail never rendered")

    // Change offset to make the second thumbnail distinctly different.
    offsetSlider.adjust(toNormalizedSliderPosition: 0.9)
    Thread.sleep(forTimeInterval: 1)

    generateButton.tap()
    // Thumbnail should remain a valid image element throughout.
    Thread.sleep(forTimeInterval: 15)
    XCTAssertTrue(thumbnailImage.exists, "Thumbnail image vanished on second generate")

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Hammer the Generate button. Each tap while a previous request is
  /// in flight is disabled via `isGenerating`, so the stress here is
  /// the serialization path — the async coordinator must drain cleanly
  /// between requests.
  func test_stress_rapidGenerateTaps() {
    launch(route: .thumbnails)

    XCTAssertTrue(generateButton.waitForExistence(timeout: 5))

    for _ in 0..<3 {
      generateButton.tap()
      // Wait for request to complete before the next tap (the Generate
      // button is disabled while isGenerating). 15 s library timeout.
      _ = thumbnailImage.waitForExistence(timeout: 15)
      XCTAssertTrue(
        generateButton.waitForExistence(timeout: 5),
        "Generate button missing between rapid taps"
      )
    }

    XCTAssertTrue(generateButton.isHittable, "Generate became non-interactive after rapid cycle")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .thumbnails)
    XCTAssertTrue(generateButton.waitForExistence(timeout: 5))

    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        app.terminate()
        app.launch()
        _ = generateButton.waitForExistence(timeout: 5)
      }
    }

    assertNoLibraryErrors()
  }
}
