@testable import SwiftVLC
import CLibVLC
import Testing

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct VideoViewFinalTests {
    private func drawable(of player: Player) -> UnsafeMutableRawPointer? {
      libvlc_media_player_get_nsobject(player.pointer)
    }

    @Test
    func `NSView VideoSurface creation`() {
      let surface = VideoSurface()
      #if canImport(AppKit)
      // `wantsLayer` is set inside `VideoView.makeNSView`, not on the
      // bare `VideoSurface()` initializer. Pin that contract so a
      // refactor that moves the side effect here would fail loudly.
      #expect(surface.wantsLayer == false)
      #else
      _ = surface
      #endif
    }

    @Test
    func `attach sets nsobject on player`() {
      let player = Player(instance: TestInstance.shared)
      let surface = VideoSurface()
      let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()

      surface.attach(to: player)
      #expect(drawable(of: player) == surfacePtr)
      surface.detach()
    }

    @Test
    func `detach clears nsobject`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      surface.attach(to: player)
      surface.detach()
      #expect(drawable(of: player) == nil)
      // A second detach should be a no-op (guard clause: attachedPlayer is nil)
      surface.detach()
    }

    @Test
    func `layout with non-zero bounds updates sublayers`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      surface.attach(to: player)

      #if canImport(AppKit)
      surface.wantsLayer = true
      surface.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
      surface.layout()
      // Call layout again with the same bounds to verify the repeated pass is safe.
      surface.layout()
      // Change bounds to trigger the sublayer update path again
      surface.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
      surface.layout()
      #elseif canImport(UIKit)
      surface.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
      surface.layoutSubviews()
      surface.layoutSubviews()
      surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
      surface.layoutSubviews()
      #endif
    }

    @Test
    func `attach same player twice is no-op`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      surface.attach(to: player)
      // Second attach with same player should hit the guard and return early
      surface.attach(to: player)
      surface.detach()
    }

    @Test
    func `multiple attach detach cycles`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()

      for _ in 0..<5 {
        surface.attach(to: player)
        surface.detach()
      }
    }

    @Test
    func `detach without attach is safe`() {
      let surface = VideoSurface()
      // attachedPlayer is nil, so detach guard returns early
      surface.detach()
    }

    @Test
    func `attach different players replaces previous`() {
      let player1 = Player(instance: TestInstance.shared)
      let player2 = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()

      surface.attach(to: player1)
      #expect(drawable(of: player1) == surfacePtr)
      surface.attach(to: player2)
      #expect(drawable(of: player1) == nil)
      #expect(drawable(of: player2) == surfacePtr)
      surface.detach()
    }

    @Test
    func `stale surface detach does not clear current drawable`() {
      let player = Player(instance: TestInstance.shared)
      let firstSurface = sizedSurface()
      let secondSurface = sizedSurface()
      let secondPtr = Unmanaged.passUnretained(secondSurface).toOpaque()

      firstSurface.attach(to: player)
      secondSurface.attach(to: player)
      #expect(drawable(of: player) == secondPtr)

      firstSurface.detach()
      #expect(drawable(of: player) == secondPtr)

      secondSurface.detach()
      #expect(drawable(of: player) == nil)
    }

    @Test
    func `playback after stop rebinds a retained drawable`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()

      surface.attach(to: player)
      player.stop()
      #expect(player.needsDrawableRebindForPlayback)

      let stoppedNativePlayer = player.pointer
      player.prepareDrawableForPlayback()
      #expect(player.pointer != stoppedNativePlayer)
      #expect(drawable(of: player) == surfacePtr)
      #expect(!player.needsDrawableRebindForPlayback)

      surface.detach()
    }

    @Test
    func `stop requires drawable rebind across surface detach and reattach`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()

      surface.attach(to: player)
      player.stop()
      surface.detach()
      #expect(drawable(of: player) == nil)
      #expect(player.needsDrawableRebindForPlayback)

      surface.attach(to: player)
      #expect(drawable(of: player) == surfacePtr)
      #expect(player.needsDrawableRebindForPlayback)

      let stoppedNativePlayer = player.pointer
      player.prepareDrawableForPlayback()
      #expect(player.pointer != stoppedNativePlayer)
      #expect(drawable(of: player) == surfacePtr)
      #expect(!player.needsDrawableRebindForPlayback)

      surface.detach()
    }

    @Test
    func `playback after stop replaces native player even before surface reattaches`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()

      surface.attach(to: player)
      player.stop()
      surface.detach()

      let stoppedNativePlayer = player.pointer
      player.prepareDrawableForPlayback()
      #expect(player.pointer != stoppedNativePlayer)
      #expect(drawable(of: player) == nil)
      #expect(!player.needsDrawableRebindForPlayback)

      surface.attach(to: player)
      #expect(drawable(of: player) == surfacePtr)

      surface.detach()
    }

    @Test
    func `layout with zero bounds does not update sublayers`() {
      let surface = VideoSurface()
      #if canImport(AppKit)
      surface.wantsLayer = true
      surface.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
      surface.layout()
      #elseif canImport(UIKit)
      surface.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
      surface.layoutSubviews()
      #endif
      // No crash = sublayer update path was correctly skipped
    }

    @Test
    func `layout after detach does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let surface = sizedSurface()
      surface.attach(to: player)
      surface.detach()

      #if canImport(AppKit)
      surface.wantsLayer = true
      surface.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
      surface.layout()
      #elseif canImport(UIKit)
      surface.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
      surface.layoutSubviews()
      #endif
    }

    private func sizedSurface() -> VideoSurface {
      #if canImport(AppKit)
      VideoSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
      #elseif canImport(UIKit)
      VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
      #endif
    }
  }
}
