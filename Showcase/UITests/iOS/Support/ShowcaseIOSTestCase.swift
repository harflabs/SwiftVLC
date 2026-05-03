import UIKit
import XCTest

/// Base class for every iOS showcase UI test.
///
/// Owns the `XCUIApplication` instance, configures the launch-arg contract
/// (fixture URL, log path, test mode), provides launch helpers, and parses
/// the library log file on teardown.
///
/// `@MainActor` matches the isolation of `XCUIApplication`, `XCUIElement`,
/// and `XCUIDevice` under Swift 6 strict concurrency. Subclasses inherit
/// the isolation, so test methods can call XCUI APIs directly.
@MainActor
class ShowcaseIOSTestCase: XCTestCase {
  private(set) var app: XCUIApplication!
  private(set) var logURL: URL!

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false

    app = XCUIApplication()

    // One log file per test, in the simulator's tmp dir. Both processes
    // (test runner and app) share the simulator filesystem, so an absolute
    // path here is reachable from both sides.
    let safeName = name
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
      .replacingOccurrences(of: "-", with: "")
    logURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uitest-\(safeName)-\(UUID().uuidString).jsonl")

    let fixtureURL = Self.fixtureURL()

    app.launchArguments += [
      LaunchArguments.uiTestMode, "YES",
      LaunchArguments.fixtureURL, fixtureURL.path,
      LaunchArguments.logPath, logURL.path
    ]
  }

  override func tearDown() async throws {
    if let logURL, FileManager.default.fileExists(atPath: logURL.path) {
      let attachment = XCTAttachment(contentsOfFile: logURL)
      attachment.name = "library-log.jsonl"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    app?.terminate()
    try await super.tearDown()
  }

  // MARK: - Launch

  /// Launches the app deep-linked to a case study, skipping the root
  /// navigation tree.
  func launch(route: UITestRoute) {
    app.launchArguments += [LaunchArguments.route, route.rawValue]
    app.launch()
  }

  /// Launches the app at the normal `RootView`. Use this for tests that
  /// exercise navigation itself.
  func launchAtRoot() {
    app.launch()
  }

  // MARK: - Log assertions

  /// Reads the current log file and returns the parsed entries.
  func readLogEntries() -> [UITestLogEntry] {
    guard
      let logURL,
      let data = try? Data(contentsOf: logURL),
      let text = String(data: data, encoding: .utf8)
    else { return [] }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    return text
      .split(whereSeparator: \.isNewline)
      .compactMap { line in
        line.data(using: .utf8).flatMap { try? decoder.decode(UITestLogEntry.self, from: $0) }
      }
  }

  /// Fails the test if the library emitted any `error`-level entries during
  /// the scenario. Call once near the end of each test method.
  func assertNoLibraryErrors(file: StaticString = #filePath, line: UInt = #line) {
    let errors = readLogEntries().filter { $0.level == "error" }
    if !errors.isEmpty {
      let summary = errors
        .prefix(5)
        .map { "  [\($0.module ?? "?")] \($0.message)" }
        .joined(separator: "\n")
      XCTFail(
        "Library emitted \(errors.count) error(s):\n\(summary)",
        file: file,
        line: line
      )
    }
  }

  // MARK: - Wait helpers

  /// Spins until `element.label == expected`, or fails after `timeout`.
  func waitForLabel(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in element.label == expected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected label '\(expected)' but found '\(element.label)' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  /// Spins until `element.label != unexpected`, or fails after `timeout`.
  func waitForLabel(
    _ element: XCUIElement,
    notEqual unexpected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in element.label != unexpected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Label still '\(unexpected)' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  /// Waits until the element's visible screen region contains real video
  /// pixels instead of the all-black drawable placeholder.
  func assertRendersNonBlackFrame(
    _ element: XCUIElement,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    var lastNonBlackRatio = 0.0
    var lastScreenScreenshot: XCUIScreenshot?
    var lastVideoRegion: UIImage?

    while Date() < deadline {
      guard element.exists else {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        continue
      }

      let screenScreenshot = XCUIScreen.main.screenshot()
      guard let videoRegion = croppedImage(screenScreenshot.image, to: element.frame) else {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        continue
      }

      lastScreenScreenshot = screenScreenshot
      lastVideoRegion = videoRegion
      lastNonBlackRatio = nonBlackSampleRatio(in: videoRegion)
      if lastNonBlackRatio >= 0.2 {
        return
      }

      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    if let lastVideoRegion {
      let attachment = XCTAttachment(image: lastVideoRegion)
      attachment.name = "black-video-region"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    if let lastScreenScreenshot {
      let attachment = XCTAttachment(screenshot: lastScreenScreenshot)
      attachment.name = "black-video-full-screen"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTFail(
      "Expected video pixels, but sampled only \(Int(lastNonBlackRatio * 100))% non-black pixels after \(timeout)s",
      file: file,
      line: line
    )
  }

  // MARK: - Fixtures

  /// The happy-path fixture: a 10s h264 + aac mp4. Short enough to keep
  /// tests fast, long enough for pause-then-verify-stalled deep tests.
  /// Generated once via ffmpeg and committed under `Fixtures/`.
  private static func fixtureURL() -> URL {
    resource(named: "test", extension: "mp4")
  }

  /// Resolves a resource bundled in the UI test target.
  /// Synced folder groups preserve the `Fixtures/` subdirectory in the
  /// bundle, so look there first; fall back to the bundle root for safety.
  private static func resource(named name: String, extension ext: String) -> URL {
    let bundle = Bundle(for: ShowcaseIOSTestCase.self)
    if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
      return url
    }
    if let url = bundle.url(forResource: name, withExtension: ext) {
      return url
    }
    fatalError("\(name).\(ext) not found in UI test bundle")
  }
}

private func nonBlackSampleRatio(in image: UIImage) -> Double {
  guard let cgImage = image.cgImage else { return 0 }

  let width = cgImage.width
  let height = cgImage.height
  guard width > 0, height > 0 else { return 0 }

  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { return 0 }

  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

  let xRange = stride(from: 0.2, through: 0.8, by: 0.1)
  let yRange = stride(from: 0.2, through: 0.8, by: 0.1)
  var sampled = 0
  var nonBlack = 0

  for yFraction in yRange {
    for xFraction in xRange {
      let x = min(width - 1, max(0, Int(Double(width) * xFraction)))
      let y = min(height - 1, max(0, Int(Double(height) * yFraction)))
      let offset = y * bytesPerRow + x * bytesPerPixel
      let red = pixels[offset]
      let green = pixels[offset + 1]
      let blue = pixels[offset + 2]
      sampled += 1
      if max(red, green, blue) > 40 {
        nonBlack += 1
      }
    }
  }

  return sampled == 0 ? 0 : Double(nonBlack) / Double(sampled)
}

private func croppedImage(_ image: UIImage, to frame: CGRect) -> UIImage? {
  guard let cgImage = image.cgImage else { return nil }

  let imageBounds = CGRect(origin: .zero, size: image.size)
  let pointRect = frame.intersection(imageBounds)
  guard pointRect.width > 0, pointRect.height > 0 else { return nil }

  let scaleX = CGFloat(cgImage.width) / image.size.width
  let scaleY = CGFloat(cgImage.height) / image.size.height
  let pixelRect = CGRect(
    x: pointRect.minX * scaleX,
    y: pointRect.minY * scaleY,
    width: pointRect.width * scaleX,
    height: pointRect.height * scaleY
  ).integral

  guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
  return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}
