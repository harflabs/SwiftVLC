import Foundation

/// Resolves fixture file URLs from the SPM resource bundle.
enum TestMedia {
  /// 0.5s silent mono WAV at 44100Hz.
  static var silenceURL: URL {
    url(for: "silence", ext: "wav")
  }

  /// 1s 64x64 black + silence, metadata: title="Test", artist="SwiftVLC", genre="Testing", track=1.
  static var testMP4URL: URL {
    url(for: "test", ext: "mp4")
  }

  /// 2s 64x64 black + 440Hz sine wave.
  static var twosecURL: URL {
    url(for: "twosec", ext: "mp4")
  }

  /// Minimal SRT subtitle file.
  static var subtitleURL: URL {
    url(for: "test", ext: "srt")
  }

  private static func url(for name: String, ext: String) -> URL {
    if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
      return url
    }
    // Fallback: resolve relative to source file
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixturesDir = thisFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    return fixturesDir.appendingPathComponent("\(name).\(ext)")
  }
}
