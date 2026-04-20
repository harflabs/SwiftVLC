import Foundation

enum TestMedia {
  /// 720p video with 5.1 surround audio. Small, reliable, CC-licensed.
  static let bigBuckBunny = URL(
    string: "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4"
  )!

  /// MKV with multiple audio tracks and embedded subtitles.
  static let tearsOfSteel = URL(
    string: "https://pub-79c73cda2d324e97b277e8a2f351acac.r2.dev/media/TOS.mkv"
  )!

  /// HLS adaptive-bitrate stream.
  static let hls = URL(
    string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
  )!
}
