#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// A forced aspect ratio must never reach libVLC while the direct Picture in
/// Picture path can host a video output.
///
/// That path renders through geometry-negotiated vmem callbacks. The pinned
/// engine's vmem display refuses a source-aspect change and libVLC then resets
/// a display that has no reset operation: a call through a null pointer, on
/// the thread that set the ratio or on the video output thread as it starts.
/// The playback tests below would end the test process without the guard.
extension Integration {
  @Suite(.tags(.mainActor, .media))
  @MainActor struct DirectPiPAspectRatioTests {
    private func nativeAspectRatio(_ player: Player) -> String? {
      guard let c = libvlc_video_get_aspect_ratio(player.pointer) else { return nil }
      defer { libvlc_free(c) }
      let string = String(cString: c)
      return string.isEmpty ? nil : string
    }

    private func decodedFrames(_ controller: PiPController) -> UInt64 {
      controller.renderer.telemetrySnapshot.decodedFrameCount
    }

    @Test
    func `A forced ratio is kept by the player and withheld from libVLC`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      defer { withExtendedLifetime(controller) {} }

      player.aspectRatio = .ratio(4, 3)

      #expect(player.aspectRatio == .ratio(4, 3))
      #expect(
        nativeAspectRatio(player) == nil,
        "the forced ratio reached libVLC while direct PiP callbacks were bound"
      )
    }

    @Test
    func `A ratio forced before the controller exists is cleared when it claims the player`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.aspectRatio = .ratio(4, 3)
      #expect(nativeAspectRatio(player) == "4:3")

      let controller = PiPController(player: player)
      defer { withExtendedLifetime(controller) {} }

      #expect(player.aspectRatio == .ratio(4, 3))
      #expect(
        nativeAspectRatio(player) == nil,
        "the first vmem output would inherit the forced ratio as it opens"
      )
    }

    @Test
    func `The withheld ratio returns to libVLC once the controller lets go`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      player.aspectRatio = .ratio(4, 3)
      #expect(nativeAspectRatio(player) == nil)

      controller.invalidateForLifecycleEnd()

      #expect(nativeAspectRatio(player) == "4:3")
    }

    @Test
    func `Fill still selects the larger fit under direct PiP`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      defer { withExtendedLifetime(controller) {} }

      player.aspectRatio = .fill

      #expect(nativeAspectRatio(player) == nil)
      #expect(libvlc_video_get_display_fit(player.pointer) == libvlc_video_fit_larger)
    }

    /// Real decoding through vmem, so not gated on `TestCondition.canPlayMedia`:
    /// see `DecodedFrameHarnessTests` for why that gate does not apply here.
    @Test
    func `Forcing a ratio during direct PiP playback keeps the process and playback alive`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let controller = PiPController(player: player)
      defer { withExtendedLifetime(controller) {} }

      do {
        // 64x64 source, so 4:3 differs from the source aspect and libVLC would
        // act on it.
        try player.play(url: TestMedia.sparseURL)
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && decodedFrames(controller) > 0
          },
          "direct PiP never decoded a frame"
        )

        player.aspectRatio = .ratio(4, 3)

        let framesAtChange = decodedFrames(controller)
        try #require(
          await poll(timeout: .seconds(5)) {
            decodedFrames(controller) >= framesAtChange + 5
          },
          "frames stopped arriving after the ratio was forced"
        )
        #expect(player.state == .playing)
        #expect(player.aspectRatio == .ratio(4, 3))
        #expect(nativeAspectRatio(player) == nil)
      } catch {
        await player.shutdown()
        throw error
      }
      await player.shutdown()
    }

    @Test
    func `A ratio forced before direct PiP playback does not break the video output`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      player.aspectRatio = .ratio(4, 3)
      let controller = PiPController(player: player)
      defer { withExtendedLifetime(controller) {} }

      do {
        try player.play(url: TestMedia.sparseURL)
        try #require(
          await poll(timeout: .seconds(10)) {
            player.state == .playing && decodedFrames(controller) >= 5
          },
          "the vmem output did not start with a ratio forced beforehand"
        )
        #expect(player.aspectRatio == .ratio(4, 3))
      } catch {
        await player.shutdown()
        throw error
      }
      await player.shutdown()
    }
  }
}
#endif
