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
