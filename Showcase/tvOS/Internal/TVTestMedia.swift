import Foundation

enum TVTestMedia {
  static var demo: URL {
    fixtureOverrideOr(bundled: "demo", withExtension: "mkv")
  }

  static var bigBuckBunny: URL {
    fixtureOverrideOr(remote: "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4")
  }

  static var hls: URL {
    fixtureOverrideOr(remote: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
  }

  static var sidecarSubtitles: URL {
    bundled("demo-sidecar", withExtension: "srt")
  }

  private static func fixtureOverrideOr(remote: String) -> URL {
    if let override = LaunchArguments.fixtureURLValue { return override }
    guard let url = URL(string: remote) else {
      preconditionFailure("Invalid remote media URL: \(remote)")
    }
    return url
  }

  private static func fixtureOverrideOr(bundled name: String, withExtension ext: String) -> URL {
    if let override = LaunchArguments.fixtureURLValue { return override }
    return bundled(name, withExtension: ext)
  }

  private static func bundled(_ name: String, withExtension ext: String) -> URL {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
      preconditionFailure("Missing bundled media resource: \(name).\(ext)")
    }
    return url
  }
}
