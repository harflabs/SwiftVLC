import Foundation

/// Contract between the UI test target (which sets these) and the showcase app
/// (which reads them via `UserDefaults`). Foundation copies any launch argument
/// of the form `-Key Value` into `NSUserDefaults` at process start, so the
/// dash-prefixed string here is the launch-arg name and the un-prefixed
/// version is the `UserDefaults` key.
enum LaunchArguments {
  /// `YES` when running under XCUITest. Gates every test-mode behavior.
  static let uiTestMode = "-UITestMode"

  /// Absolute path to a media file. When set, every `TestMedia.*` URL
  /// resolves to this file instead of its remote source.
  static let fixtureURL = "-UITestFixtureURL"

  /// Absolute path where the showcase mirrors `VLCInstance.shared.logStream`
  /// as JSONL records (one entry per line).
  static let logPath = "-UITestLogPath"

  /// Name of a case study to deep-link to on launch (e.g. `"SimplePlayback"`).
  /// When unset, the showcase opens its normal `RootView` navigation tree.
  static let route = "-UITestRoute"

  static var isUITestMode: Bool {
    UserDefaults.standard.bool(forKey: key(uiTestMode))
  }

  static var fixtureURLValue: URL? {
    UserDefaults.standard.string(forKey: key(fixtureURL)).map { URL(fileURLWithPath: $0) }
  }

  static var logPathValue: String? {
    UserDefaults.standard.string(forKey: key(logPath))
  }

  static var routeValue: String? {
    UserDefaults.standard.string(forKey: key(route))
  }

  private static func key(_ argument: String) -> String {
    String(argument.dropFirst())
  }
}

/// The case study a test wants to deep-link into. The raw value is what the
/// test passes via `-UITestRoute <raw>` and what the showcase reads to
/// resolve the matching view.
enum UITestRoute: String, CaseIterable {
  case simplePlayback = "SimplePlayback"

  static var current: UITestRoute? {
    LaunchArguments.routeValue.flatMap(UITestRoute.init(rawValue:))
  }
}
