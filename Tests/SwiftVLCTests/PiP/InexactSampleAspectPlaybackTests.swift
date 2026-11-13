#if os(iOS) || os(macOS)
@testable import SwiftVLC
import Foundation
import Testing

/// Issue 250: media whose sample aspect ratio has no integer square-pixel
/// size played audio over a picture that never appeared on the direct Picture
/// in Picture path, with libVLC still reporting `playing`.
///
/// Two checks refused such media. SwiftVLC's format callback now rounds to the
/// nearest pixel (`PixelBufferGeometryTests`); the vmem output's own check
/// needs the rebuilt engine, which accepts a size within half a pixel. Until
/// that engine is the one linked, libVLC still refuses the rounded size, so
/// this playback test is gated like the other rebuilt-engine tests.
extension Integration {
  @Suite(.tags(.mainActor, .media))
  @MainActor struct InexactSampleAspectPlaybackTests {
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1",
        "Requires the rebuilt release XCFramework"
      )
    )
    func `A 817 by 816 sample aspect decodes through direct PiP`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let controller = PiPController(player: player)
      defer { withExtendedLifetime(controller) {} }

      do {
        try player.play(url: TestMedia.inexactSARURL)
        try #require(
          await poll(timeout: .seconds(10)) {
            controller.renderer.telemetrySnapshot.decodedFrameCount >= 5
          },
          "no picture reached the direct PiP renderer"
        )
        #expect(player.state == .playing)
      } catch {
        await player.shutdown()
        throw error
      }
      await player.shutdown()
    }
  }
}
#endif
