#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Covers `PiPVideoView` paths that don't require a live SwiftUI
/// scene: the `init`, `makeCoordinator`, and the static dismantle
/// hook that SwiftUI calls when the view is removed from the tree.
///
/// The full `makeUIView` / `makeNSView` path is harder to hit without
/// a SwiftUI host — we drive the coordinator directly instead, which
/// is where the actual lifecycle logic lives.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPVideoViewTests {
    @Test
    func `Init without binding does not crash`() {
      let player = Player(instance: TestInstance.shared)
      _ = PiPVideoView(player)
    }

    @Test
    func `Init with controller binding does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      _ = PiPVideoView(player, controller: binding)
    }

    @Test
    func `makeCoordinator returns a usable Coordinator`() {
      let player = Player(instance: TestInstance.shared)
      let view = PiPVideoView(player)

      let coordinator = view.makeCoordinator()
      // Fresh coordinator has no references.
      #expect(coordinator.pipController == nil)
      #if canImport(UIKit)
      #expect(coordinator.displayLayer == nil)
      #endif
      #expect(coordinator.player == nil)
    }

    /// Dismantle on an empty coordinator is a safe no-op: no
    /// controller to stop and no drawable attachment to clear.
    @Test
    func `dismantle on empty coordinator is a no-op`() {
      let player = Player(instance: TestInstance.shared)
      let view = PiPVideoView(player)
      let coordinator = view.makeCoordinator()

      #if canImport(UIKit)
      let container = UIView()
      PiPVideoView.dismantleUIView(container, coordinator: coordinator)
      #elseif canImport(AppKit)
      let container = MacNativePiPHostView()
      PiPVideoView.dismantleNSView(container, coordinator: coordinator)
      #endif
    }

    /// Dismantle with a controller attached must stop it and clear
    /// coordinator-owned controller state.
    @Test
    func `dismantle with attached controller clears state`() {
      let player = Player(instance: TestInstance.shared)
      let view = PiPVideoView(player)
      let coordinator = view.makeCoordinator()

      // Simulate what makeUIView/makeNSView would do: attach a
      // controller to the coordinator.
      let controller = PiPController(player: player)
      coordinator.pipController = controller
      #if canImport(UIKit)
      coordinator.displayLayer = controller.layer
      #endif
      coordinator.player = player

      #if canImport(UIKit)
      let container = UIView()
      PiPVideoView.dismantleUIView(container, coordinator: coordinator)
      #elseif canImport(AppKit)
      let container = MacNativePiPHostView()
      PiPVideoView.dismantleNSView(container, coordinator: coordinator)
      #endif

      #expect(coordinator.pipController == nil)
      #if canImport(UIKit)
      #expect(coordinator.displayLayer == nil)
      #endif
    }

    #if canImport(AppKit)
    @Test
    func `macOS native PiP host attaches drawable child`() {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()

      host.attach(to: player)
      #expect(player.drawable === host.drawableView)

      host.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `macOS native PiP drawable attaches and detaches player drawable`() {
      let player = Player(instance: TestInstance.shared)
      let view = MacNativePiPDrawableView()

      view.attach(to: player)
      #expect(player.drawable === view)

      view.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `macOS dismantle detaches native PiP drawable and clears controller`() {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()
      let view = PiPVideoView(player)
      let coordinator = view.makeCoordinator()
      let controller = PiPController(player: player, nativeBackend: host.nativePiPBackend)

      host.attach(to: player)
      coordinator.player = player
      coordinator.pipController = controller

      PiPVideoView.dismantleNSView(host, coordinator: coordinator)

      #expect(player.drawable == nil)
      #expect(coordinator.pipController == nil)

      host.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `macOS native PiP drawable does not expose VLC AVKit PiP callbacks`() {
      let view = MacNativePiPDrawableView()

      #expect(view.responds(to: NSSelectorFromString("pictureInPictureReady")) == false)
      #expect(view.responds(to: NSSelectorFromString("mediaController")) == false)
      #expect(view.responds(to: NSSelectorFromString("canStartPictureInPictureAutomaticallyFromInline")) == false)
    }

    @Test
    func `macOS native PiP drawable exposes VLC embedding callbacks`() {
      let view = MacNativePiPDrawableView()

      #expect(view.responds(to: NSSelectorFromString("addVoutSubview:")))
      #expect(view.responds(to: NSSelectorFromString("removeVoutSubview:")))
    }

    @Test
    func `macOS native PiP drawable sizes VLC content to its bounds`() {
      let view = MacNativePiPDrawableView()
      view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
      let vlcSubview = NSView()
      view.addSubview(vlcSubview)
      view.layoutSubtreeIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 640, height: 360))
      #expect(vlcSubview.autoresizingMask == [.width, .height])

      view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
      view.layoutSubtreeIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 480, height: 270))
      #expect(vlcSubview.autoresizingMask == [.width, .height])
    }

    @Test
    func `macOS native PiP restore repeats full-size VLC content layout`() async {
      let host = MacNativePiPHostView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
      let drawable = host.drawableView
      let vlcSubview = PiPReshapeProbeView()

      drawable.addVoutSubview(vlcSubview)
      host.layoutSubtreeIfNeeded()

      func restoreFromPiPSize() {
        drawable.removeFromSuperview()
        drawable.frame = CGRect(x: 0, y: 0, width: 426, height: 240)
        vlcSubview.frame = drawable.bounds

        host.restoreDrawableView(drawable)
      }

      restoreFromPiPSize()
      restoreFromPiPSize()

      #expect(drawable.superview === host)
      #expect(drawable.frame.size == host.bounds.size)
      #expect(vlcSubview.frame.size == host.bounds.size)
      #expect(vlcSubview.reshapeCount >= 2)

      await Task.yield()

      #expect(drawable.superview === host)
      #expect(drawable.frame.size == host.bounds.size)
      #expect(vlcSubview.frame.size == host.bounds.size)
      #expect(vlcSubview.reshapeCount >= 3)
    }

    @Test
    func `macOS native PiP rejects instances without video output`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--no-video", "--no-audio", "--quiet"])
      let player = Player(instance: instance)
      let backend = MacNativePiPBackend()

      backend.attach(to: player)

      #expect(backend.isPossible == false)
    }

    @Test
    func `macOS native PiP media controller reports playback intent`() {
      let player = Player(instance: TestInstance.shared)
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player

      #expect(mediaController.isMediaPlaying() == false)

      player.setPlaybackIntentFromExternalControl(true)
      #expect(mediaController.isMediaPlaying() == true)

      player.setPlaybackIntentFromExternalControl(false)
      #expect(mediaController.isMediaPlaying() == false)
    }
    #endif
  }
}

/// Reference-cell backing for a test-built SwiftUI `Binding`. Avoids
/// pulling in `@State`, which requires a real view hierarchy.
private final class Box<T> {
  var value: T
  init(_ initial: T) {
    value = initial
  }
}

#if canImport(AppKit)
@MainActor
private final class PiPReshapeProbeView: NSView {
  var reshapeCount = 0

  @objc(reshape)
  func reshapeForTesting() {
    reshapeCount += 1
  }
}
#endif
#endif
