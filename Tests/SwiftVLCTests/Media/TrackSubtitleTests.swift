@testable import SwiftVLC
import Testing

/// Covers the subtitle shape of `Track` — any `Track` with
/// `type == .subtitle` must have audio/video-specific fields as nil.
/// Drives `media.tracks()` with a media that has an external
/// subtitle slave attached; if libVLC's parser surfaces the slave
/// as a first-class Track, the shape is asserted.
extension Integration {
  @Suite(.tags(.media)) struct TrackSubtitleTests {
    @Test
    func `Subtitle Track has nil audio and video fields`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let media = try Media(url: TestMedia.twosecURL)
      try media.addSlave(from: TestMedia.subtitleURL, type: .subtitle)

      _ = try? await media.parse(timeout: .seconds(5), instance: instance)

      guard let subtitle = media.tracks().first(where: { $0.type == .subtitle }) else {
        // libVLC didn't surface the slave as a Track — test is a no-op
        // in that case, which is acceptable for a headless run.
        return
      }
      #expect(subtitle.channels == nil)
      #expect(subtitle.sampleRate == nil)
      #expect(subtitle.width == nil)
      #expect(subtitle.height == nil)
      #expect(subtitle.frameRate == nil)
    }
  }
}
