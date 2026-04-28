import Foundation

/// Contract between the UI test target (which sets these) and the showcase app
/// (which reads them via `UserDefaults`). Foundation copies any launch argument
/// of the form `-Key Value` into `NSUserDefaults` at process start, so the
/// dash-prefixed string here is the launch-arg name and the un-prefixed
/// version is the `UserDefaults` key.
enum LaunchArguments {
  /// `YES` when running under XCUITest. Gates every test-mode behavior.
  static let uiTestMode = "-UITestMode"

  /// Absolute path to a media file. When set, showcase media helpers resolve
  /// to this file instead of their bundled or remote sources.
  static let fixtureURL = "-UITestFixtureURL"

  /// Absolute path where the showcase mirrors `VLCInstance.shared.logStream`
  /// as JSONL records (one entry per line).
  static let logPath = "-UITestLogPath"

  /// Name of a showcase to deep-link to on launch (e.g. `"SimplePlayback"`).
  /// When unset, the showcase opens its normal navigation tree.
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

/// The showcase a test wants to deep-link into. The raw value is what the
/// test passes via `-UITestRoute <raw>` and what the showcase reads to
/// resolve the matching view.
enum UITestRoute: String, CaseIterable {
  case videoPlayer = "VideoPlayer"
  case musicPlayer = "MusicPlayer"
  case simplePlayback = "SimplePlayback"
  case playerState = "PlayerState"
  case seeking = "Seeking"
  case volume = "Volume"
  case abLoop = "ABLoop"
  case relativeSeek = "RelativeSeek"
  case frameStep = "FrameStep"
  case rate = "Rate"
  case thumbnails = "Thumbnails"
  case audioTracks = "AudioTracks"
  case snapshot = "Snapshot"
  case pip = "PiP"
  case audioOutputs = "AudioOutputs"
  case lifecycle = "Lifecycle"
  case aspectRatio = "AspectRatio"
  case deinterlacing = "Deinterlacing"
  case equalizer = "Equalizer"
  case audioChannels = "AudioChannels"
  case audioDelay = "AudioDelay"
  case recording = "Recording"
  case marquee = "Marquee"
  case adjustments = "Adjustments"
  case viewpoint = "Viewpoint"
  case subtitlesSelection = "SubtitlesSelection"
  case subtitlesExternal = "SubtitlesExternal"
  case chapters = "Chapters"
  case subtitlesDelay = "SubtitlesDelay"
  case subtitlesScale = "SubtitlesScale"
  case streamingHLS = "StreamingHLS"
  case playlistQueue = "PlaylistQueue"
  case discoveryLAN = "DiscoveryLAN"
  case discoveryRenderers = "DiscoveryRenderers"
  case metadata = "Metadata"
  case events = "Events"
  case statistics = "Statistics"
  case logs = "Logs"
  case thumbnailScrub = "ThumbnailScrub"
  case roleAndCork = "RoleAndCork"
  case multiTrackSelection = "MultiTrackSelection"
  case multiConsumer = "MultiConsumer"

  static var current: UITestRoute? {
    LaunchArguments.routeValue.flatMap(UITestRoute.init(rawValue:))
  }
}
