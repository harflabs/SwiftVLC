import Foundation

enum TestMedia {
  /// Bundled multi-track demo reel. The rendered MKV is committed in-tree:
  /// 60 seconds, three video variants (1080p / 720p / 480p), three audio
  /// tracks, three subtitle tracks (one RTL), six named chapters, rich global
  /// metadata, and an attached cover image.
  static var demo: URL {
    fixtureOverrideOr(bundled: "demo", withExtension: "mkv")
  }

  /// 720p video with 5.1 surround audio. Small, reliable, CC-licensed.
  static var bigBuckBunny: URL {
    fixtureOverrideOr(remote: "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4")
  }

  /// HLS adaptive-bitrate stream.
  static var hls: URL {
    fixtureOverrideOr(remote: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
  }

  /// Returns the local fixture path injected by XCUITest, or the remote URL
  /// in normal use. The override is a single file shared by every showcase
  /// that needs media — the test asserts behavior, not source-specific quirks.
  private static func fixtureOverrideOr(remote: String) -> URL {
    LaunchArguments.fixtureURLValue ?? URL(string: remote)!
  }

  private static func fixtureOverrideOr(bundled name: String, withExtension ext: String) -> URL {
    if let override = LaunchArguments.fixtureURLValue { return override }
    return Bundle.main.url(forResource: name, withExtension: ext)!
  }
}
