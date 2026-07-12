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

  /// Spins until an accessibility label parses as an integer above the
  /// supplied lower bound, then returns the observed value.
  @discardableResult
  func waitForIntegerLabel(
    _ element: XCUIElement,
    greaterThan lowerBound: Int,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Int {
    let predicate = NSPredicate { _, _ in
      Int(element.label).map { $0 > lowerBound } == true
    }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected an integer label above \(lowerBound), but found '\(element.label)' after \(timeout)s",
        file: file,
        line: line
      )
    }
    return Int(element.label) ?? Int.min
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

  /// Samples the display after backgrounding and finds one stable, contiguous
  /// PiP-sized motion component. The same bounded region must contain
  /// sustained motion and non-black pixels; whole-screen animation, clocks,
  /// widgets, spinners, scattered changes, and position drift are rejected.
  func assertSystemPictureInPictureRendersMotion(
    samples: Int = 6,
    interval: TimeInterval = 0.75,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    precondition(samples >= 5)

    var screenshots: [XCUIScreenshot] = []

    for index in 0..<samples {
      screenshots.append(XCUIScreen.main.screenshot())
      if index + 1 < samples {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
      }
    }

    for (index, screenshot) in screenshots.enumerated()
      where index == 0 || index == screenshots.count - 1 {
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = index == 0 ? "system-pip-motion-start" : "system-pip-motion-end"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    let frames = screenshots.compactMap { makePiPMotionFrame(from: $0.image) }
    guard frames.count == screenshots.count else {
      let attachment = XCTAttachment(
        string: "Could rasterize only \(frames.count) of \(screenshots.count) screenshots."
      )
      attachment.name = "system-pip-motion-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTFail("Could not rasterize system PiP screenshots", file: file, line: line)
      return
    }

    let analysis = PiPMotionRegionAnalyzer().analyze(frames)
    let diagnostics = systemPiPMotionDiagnostics(analysis)
    let diagnosticAttachment = XCTAttachment(string: diagnostics)
    diagnosticAttachment.name = "system-pip-motion-diagnostics"
    diagnosticAttachment.lifetime = .keepAlways
    add(diagnosticAttachment)

    if
      let region = analysis.region,
      let first = screenshots.first,
      let last = screenshots.last {
      for (name, screenshot) in [("start", first), ("end", last)] {
        guard
          let crop = croppedPiPMotionRegion(
            screenshot.image,
            region: region,
            frameWidth: analysis.frameWidth,
            frameHeight: analysis.frameHeight
          )
        else { continue }
        let attachment = XCTAttachment(image: crop)
        attachment.name = "system-pip-detected-region-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }

    guard let failure = analysis.failure else { return }
    XCTFail(
      "System PiP image oracle failed: \(failure.rawValue). \(diagnostics)",
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

private func makePiPMotionFrame(
  from image: UIImage,
  maximumDimension: Int = 240
) -> PiPMotionFrame? {
  guard let cgImage = image.cgImage else { return nil }

  let sourceWidth = cgImage.width
  let sourceHeight = cgImage.height
  guard sourceWidth > 0, sourceHeight > 0 else { return nil }

  let scale = min(
    1,
    Double(maximumDimension) / Double(max(sourceWidth, sourceHeight))
  )
  let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
  let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    | CGBitmapInfo.byteOrder32Big.rawValue
  var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)

  guard
    let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    )
  else { return nil }

  context.interpolationQuality = .low
  let bounds = CGRect(x: 0, y: 0, width: width, height: height)
  context.draw(cgImage, in: bounds)

  var pixels: [PiPMotionPixel] = []
  pixels.reserveCapacity(width * height)
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * bytesPerRow + x * bytesPerPixel
      pixels.append(
        PiPMotionPixel(
          red: bytes[offset],
          green: bytes[offset + 1],
          blue: bytes[offset + 2]
        )
      )
    }
  }

  return PiPMotionFrame(width: width, height: height, pixels: pixels)
}

private func croppedPiPMotionRegion(
  _ image: UIImage,
  region: PiPMotionRegion,
  frameWidth: Int,
  frameHeight: Int
) -> UIImage? {
  guard
    let cgImage = image.cgImage,
    frameWidth > 0,
    frameHeight > 0
  else { return nil }

  let scaleX = Double(cgImage.width) / Double(frameWidth)
  let scaleY = Double(cgImage.height) / Double(frameHeight)
  let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
  let pixelRegion = CGRect(
    x: Double(region.x) * scaleX,
    y: Double(region.y) * scaleY,
    width: Double(region.width) * scaleX,
    height: Double(region.height) * scaleY
  ).integral.intersection(imageBounds)
  guard pixelRegion.width > 0, pixelRegion.height > 0 else { return nil }
  guard let cropped = cgImage.cropping(to: pixelRegion) else { return nil }
  return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}

private func systemPiPMotionDiagnostics(_ analysis: PiPMotionRegionAnalysis) -> String {
  let regionDescription = analysis.region.map {
    "x=\($0.x),y=\($0.y),w=\($0.width),h=\($0.height)"
  } ?? "none"
  let pairMotion = analysis.pairMotionRatios
    .map { String(format: "%.4f", $0) }
    .joined(separator: ",")
  let nonBlack = analysis.frameNonBlackRatios
    .map { String(format: "%.4f", $0) }
    .joined(separator: ",")

  return """
  result=\(analysis.failure?.rawValue ?? "pass")
  frame=\(analysis.frameWidth)x\(analysis.frameHeight)
  region=\(regionDescription)
  geometry.area=\(String(format: "%.4f", analysis.regionAreaRatio))
  geometry.aspect=\(String(format: "%.4f", analysis.regionAspectRatio))
  geometry.persistentFill=\(String(format: "%.4f", analysis.persistentFillRatio))
  persistent.components=\(analysis.persistentComponentCount)
  persistent.largestArea=\(String(format: "%.4f", analysis.largestPersistentComponentAreaRatio))
  pairs.matching=\(analysis.matchingPairCount)/\(analysis.requiredPairCount)
  pairs.sustainedMotion=\(analysis.sustainedMotionPairCount)/\(analysis.requiredPairCount)
  pairs.motionRatios=[\(pairMotion)]
  frames.nonBlack=\(analysis.nonBlackFrameCount)/\(analysis.requiredNonBlackFrameCount) required
  frames.nonBlackRatios=[\(nonBlack)]
  drift.horizontal=\(String(format: "%.4f", analysis.horizontalCenterDriftRatio))
  drift.vertical=\(String(format: "%.4f", analysis.verticalCenterDriftRatio))
  """
}
