@testable import SwiftVLC
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Covers `VideoSurface` — the internal UIView/NSView that `VideoView`
/// constructs to bridge libVLC's `set_nsobject` rendering.
///
/// `VideoSurface` is hard to exercise via `VideoView` (which is a
/// SwiftUI representable that needs a real view host). Constructing
/// the surface directly lets us exercise `attach` / `detach` /
/// re-attach lifecycles without a SwiftUI scene.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct VideoSurfaceTests {
    @Test
    func `attach stores the player reference`() {
      let player = Player(instance: TestInstance.shared)
      let surface = VideoSurface()

      surface.attach(to: player)

      // Re-attaching the same player is a no-op — verified by the
      // fact that this test doesn't crash and the surface remains
      // usable afterwards.
      surface.attach(to: player)
    }

    @Test
    func `attach then detach clears the player reference`() {
      let player = Player(instance: TestInstance.shared)
      let surface = VideoSurface()

      surface.attach(to: player)
      surface.detach()

      // detach on an already-detached surface must be a safe no-op.
      surface.detach()
    }

    /// Re-attaching to a different player must first detach the prior
    /// one from libVLC — otherwise the old player's render sublayer
    /// leaks and the new player gets no surface.
    @Test
    func `re-attaching to a different player switches surfaces cleanly`() {
      let playerA = Player(instance: TestInstance.shared)
      let playerB = Player(instance: TestInstance.shared)
      let surface = VideoSurface()

      surface.attach(to: playerA)
      surface.attach(to: playerB)
      // Dropping the surface after a clean attach should not crash
      // either player.
      #expect(playerA.state == .idle)
      #expect(playerB.state == .idle)
    }

    /// Detach without a prior attach is a no-op.
    @Test
    func `detach without attach does not crash`() {
      let surface = VideoSurface()
      surface.detach()
    }

    /// Surface deinit while still attached must not leave libVLC
    /// holding a dangling view pointer. We can't assert on the libVLC
    /// side directly, but we can confirm the player remains usable
    /// after the surface is dropped.
    @Test
    func `Dropping a still-attached surface leaves the player usable`() {
      let player = Player(instance: TestInstance.shared)
      do {
        let surface = VideoSurface()
        surface.attach(to: player)
      }
      #expect(player.state == .idle)
    }

    /// Resizing the surface fires the layout pass that syncs any
    /// libVLC-owned sublayer frames to the new bounds. Without a
    /// valid bounds width and height, the layout is a no-op.
    @Test
    func `Layout pass with non-zero bounds syncs sublayer frames`() {
      #if canImport(UIKit)
      let surface = VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
      let sublayer = CALayer()
      sublayer.frame = .zero
      surface.layer.addSublayer(sublayer)
      // Force a new bounds so the `bounds != lastBounds` branch hits.
      surface.bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
      surface.layoutSubviews()
      #expect(sublayer.frame == surface.bounds)
      #elseif canImport(AppKit)
      let surface = VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
      surface.wantsLayer = true
      let sublayer = CALayer()
      sublayer.frame = .zero
      surface.layer?.addSublayer(sublayer)
      surface.bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
      surface.layout()
      #expect(sublayer.frame == surface.bounds)
      #endif
    }

    @Test
    func `AppKit surface pins and reshapes VLC subviews to local bounds`() {
      #if canImport(AppKit)
      let surface = VideoSurface(frame: NSRect(x: 120, y: 80, width: 320, height: 180))
      surface.wantsLayer = true
      surface.layer?.masksToBounds = true

      let vlcSubview = AppKitReshapeProbeView(frame: surface.frame)
      surface.addSubview(vlcSubview)

      #expect(vlcSubview.frame == surface.bounds)
      #expect(vlcSubview.autoresizingMask.contains(.width))
      #expect(vlcSubview.autoresizingMask.contains(.height))
      #expect(vlcSubview.reshapeCount == 1)
      #expect(surface.wantsDefaultClipping)
      #expect(surface.layer?.masksToBounds == true)

      surface.setFrameSize(NSSize(width: 640, height: 360))
      surface.layoutSubtreeIfNeeded()

      #expect(vlcSubview.frame == surface.bounds)
      #expect(vlcSubview.reshapeCount >= 2)
      #else
      #expect(Bool(true))
      #endif
    }

    /// Layout with zero-width or zero-height bounds must be a no-op
    /// so we don't race with libVLC's own initial sizing.
    @Test
    func `Layout with zero bounds does not sync sublayer frames`() {
      let sublayer = CALayer()
      sublayer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

      #if canImport(UIKit)
      let surface = VideoSurface(frame: .zero)
      surface.layer.addSublayer(sublayer)
      surface.bounds = .zero
      surface.layoutSubviews()
      #expect(sublayer.frame == CGRect(x: 0, y: 0, width: 100, height: 100))
      #elseif canImport(AppKit)
      let surface = VideoSurface(frame: .zero)
      surface.wantsLayer = true
      surface.layer?.addSublayer(sublayer)
      surface.bounds = .zero
      surface.layout()
      #expect(sublayer.frame == CGRect(x: 0, y: 0, width: 100, height: 100))
      #endif
    }
  }
}

#if canImport(AppKit)
@MainActor
private final class AppKitReshapeProbeView: NSView {
  var reshapeCount = 0

  @objc(reshape)
  func reshapeForTesting() {
    reshapeCount += 1
  }
}
#endif
