#if os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AppKit
import CLibVLC
import Foundation
import Testing

extension Integration {
  /// The private macOS Picture in Picture panel takes the shape the picture
  /// is displayed in, not the shape of the view that hosts it inline.
  @Suite(.tags(.mainActor))
  @MainActor struct MacPiPPanelShapeTests {
    @Test
    func `macOS private PiP panel takes the shape of the video, not of its host`() async {
      let player = Player(instance: TestInstance.shared)
      // A landscape video in a portrait view.
      player._videoDisplaySizeOverrideForTesting = CGSize(width: 1920, height: 1080)
      let host = MacNativePiPHostView(frame: CGRect(x: 0, y: 0, width: 540, height: 960))
      let drawable = host.drawableView
      let controller = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(
        pictureInPictureViewControllerFactory: { controller }
      )
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player

      let didStart = presenter.start(
        player: player,
        hostView: host,
        drawableView: drawable,
        mediaController: mediaController,
        onActiveChanged: { _ in },
        onPlay: {},
        onPause: {}
      )

      #expect(didStart)
      #expect(controller.aspectRatio?.sizeValue == CGSize(width: 1920, height: 1080))
      #expect(controller.presentedViewController?.view.frame.size == CGSize(width: 540, height: 304))

      // The next item is portrait: the open panel follows it.
      player._videoDisplaySizeOverrideForTesting = CGSize(width: 1080, height: 1920)
      player.withMutation(keyPath: \.videoSize) {}
      for _ in 0..<5 where controller.aspectRatio?.sizeValue != CGSize(width: 1080, height: 1920) {
        await Task.yield()
      }
      #expect(controller.aspectRatio?.sizeValue == CGSize(width: 1080, height: 1920))

      // A forced aspect ratio is the shape the picture is displayed in.
      player.aspectRatio = .ratio(4, 3)
      for _ in 0..<5 where controller.aspectRatio?.sizeValue != CGSize(width: 64, height: 48) {
        await Task.yield()
      }
      #expect(controller.aspectRatio?.sizeValue == CGSize(width: 64, height: 48))

      presenter.stop()
      #expect(drawable.frame == host.bounds)
    }

    @Test
    func `macOS private PiP panel falls back to the host shape without a video size`() {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
      let controller = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(
        pictureInPictureViewControllerFactory: { controller }
      )
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player

      let didStart = presenter.start(
        player: player,
        hostView: host,
        drawableView: host.drawableView,
        mediaController: mediaController,
        onActiveChanged: { _ in },
        onPlay: {},
        onPause: {}
      )
      #expect(didStart)
      #expect(controller.aspectRatio?.sizeValue == CGSize(width: 960, height: 540))
      presenter.stop()
    }

    @Test
    func `display size applies the sample aspect ratio and rotation`() {
      // PAL anamorphic widescreen: 720x576 stored, 1024x576 displayed.
      #expect(Player.displaySize(
        width: 720, height: 576, sampleAspectRatio: (64, 45), orientation: libvlc_video_orient_top_left
      ) == CGSize(width: 1024, height: 576))
      // A phone recording stored landscape with a quarter-turn flag.
      #expect(Player.displaySize(
        width: 1920, height: 1080, sampleAspectRatio: (1, 1), orientation: libvlc_video_orient_left_bottom
      ) == CGSize(width: 1080, height: 1920))
      #expect(Player.displaySize(
        width: 1920, height: 1080, sampleAspectRatio: (1, 1), orientation: libvlc_video_orient_bottom_right
      ) == CGSize(width: 1920, height: 1080))
      // An unknown ratio means square pixels.
      #expect(Player.displaySize(
        width: 1280, height: 720, sampleAspectRatio: (0, 0), orientation: libvlc_video_orient_top_left
      ) == CGSize(width: 1280, height: 720))
    }
  }
}
#endif
