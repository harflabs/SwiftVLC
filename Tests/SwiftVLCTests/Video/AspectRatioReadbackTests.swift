@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// Characterizes the libVLC video-configuration state each `AspectRatio` case
/// drives, read back through `libvlc_video_get_aspect_ratio` and
/// `libvlc_video_get_display_fit`. These are API-level readbacks — they prove
/// which knobs the wrapper sets, not what the vout renders (the sample-buffer
/// display honors the source SAR, not the fit variable). On-screen geometry is
/// covered by `scripts/aspect-harness`.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct AspectRatioReadbackTests {
    private func aspectString(_ player: Player) -> String? {
      guard let c = libvlc_video_get_aspect_ratio(player.pointer) else { return nil }
      defer { libvlc_free(c) }
      let s = String(cString: c)
      return s.isEmpty ? nil : s
    }

    private func displayFit(_ player: Player) -> libvlc_video_fit_mode_t {
      libvlc_video_get_display_fit(player.pointer)
    }

    @Test
    func `default sets no forced aspect and the smaller fit`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .default
      #expect(aspectString(player) == nil)
      #expect(displayFit(player) == libvlc_video_fit_smaller)
    }

    @Test
    func `ratio sets the forced aspect string`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .ratio(16, 9)
      #expect(aspectString(player) == "16:9")
    }

    @Test
    func `fill requests the larger fit`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .fill
      #expect(displayFit(player) == libvlc_video_fit_larger)
    }

    /// The aspect mode must reapply to the replacement handle so a stop/play
    /// or recast keeps `.fill` covering rather than reverting to letterbox.
    @Test
    func `fill survives a native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.aspectRatio = .fill
      let old = player.pointer
      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()
      try #require(player.pointer != old, "swap did not replace the native handle")
      #expect(displayFit(player) == libvlc_video_fit_larger)
    }
  }
}
