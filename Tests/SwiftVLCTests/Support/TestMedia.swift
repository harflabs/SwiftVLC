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

  /// 2s 64x64 black + audio with an embedded English `mov_text` subtitle track.
  static var internalSubtitlesURL: URL {
    url(for: "internal-subtitles", ext: "mp4")
  }

  /// 20s 64x64 black, video-only, keyframes only at ~0s and ~10s —
  /// the sparse-GOP fixture that makes fast (keyframe) and precise
  /// seeks land visibly apart.
  static var sparseURL: URL {
    url(for: "sparse", ext: "mp4")
  }

  /// 6s 64x48 test pattern, video-only, sample aspect ratio 817:816 — a ratio
  /// with no integer square-pixel size (issue 250).
  static var inexactSARURL: URL {
    url(for: "inexact-sar", ext: "mp4")
  }

  /// Minimal SRT subtitle file.
  static var subtitleURL: URL {
    url(for: "test", ext: "srt")
  }

  /// Overlapping WebVTT cues covering placement defaults, anchors, and invalid settings.
  static var webVTTPlacementURL: URL {
    url(for: "webvtt-placement", ext: "vtt")
  }

  /// Simultaneous WebVTT cues covering region retention and explicit size dropout.
  static var webVTTRegionURL: URL {
    url(for: "webvtt-region", ext: "vtt")
  }

  /// Long SRT cue used to prove non-WebVTT decoder provenance.
  static var automaticSRTURL: URL {
    url(for: "automatic", ext: "srt")
  }

  /// Explicitly positioned TTML cue used to reject geometry-based WebVTT inference.
  static var positionedTTMLURL: URL {
    url(for: "positioned", ext: "ttml")
  }

  /// 10s: tiny video, eng/ara AAC, and eng/ara SRT tracks with stable ids.
  static var multitrackMKVURL: URL {
    url(for: "multitrack", ext: "mkv", in: "tracks")
  }

  /// 10s HLS: tiny video variant, eng/ara audio renditions, and an English
  /// WebVTT rendition, all with unstable adaptive ids.
  static var multitrackHLSURL: URL {
    url(for: "master", ext: "m3u8", in: "tracks/hls")
  }

  private static func url(for name: String, ext: String, in directory: String? = nil) -> URL {
    let subdirectory = ["Fixtures", directory].compactMap(\.self).joined(separator: "/")
    if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
      return url
    }
    // Fallback: resolve relative to source file
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixturesDir = thisFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(subdirectory)
    return fixturesDir.appendingPathComponent("\(name).\(ext)")
  }
}
