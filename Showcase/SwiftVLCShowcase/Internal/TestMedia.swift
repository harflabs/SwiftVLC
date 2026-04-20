import Foundation

enum TestMedia {
  /// 720p video with 5.1 surround audio. Small, reliable, CC-licensed.
  static var bigBuckBunny: URL {
    fixtureOverrideOr(remote: "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4")
  }

  /// MKV with multiple audio tracks and embedded subtitles.
  static var tearsOfSteel: URL {
    fixtureOverrideOr(remote: "https://pub-79c73cda2d324e97b277e8a2f351acac.r2.dev/media/TOS.mkv")
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
}
