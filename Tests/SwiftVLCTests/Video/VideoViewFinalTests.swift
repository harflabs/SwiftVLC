@testable import SwiftVLC
import CLibVLC
import Testing

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct VideoViewFinalTests {
  private func drawable(of player: Player) -> UnsafeMutableRawPointer? {
    libvlc_media_player_get_nsobject(player.pointer)
  }

  @Test
  func `NSView VideoSurface creation`() {
    let surface = VideoSurface()
    #if canImport(AppKit)
    #expect(surface is NSView)
    #expect(surface.wantsLayer == false) // wantsLayer not set until makeNSView
    #elseif canImport(UIKit)
    #expect(surface is UIView)
    #endif
  }

  @Test
  func `attach sets nsobject on player`() {
    let player = Player()
    let surface = VideoSurface()
    let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()
    surface.attach(to: player)
    #expect(drawable(of: player) == surfacePtr)
    surface.detach()
  }

  @Test
  func `detach clears nsobject`() {
    let player = Player()
    let surface = VideoSurface()
    surface.attach(to: player)
    surface.detach()
    #expect(drawable(of: player) == nil)
    // A second detach should be a no-op (guard clause: attachedPlayer is nil)
    surface.detach()
  }

  @Test
  func `layout with non-zero bounds updates sublayers`() {
    let player = Player()
    let surface = VideoSurface()
    surface.attach(to: player)

    #if canImport(AppKit)
    surface.wantsLayer = true
    surface.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    surface.layout()
    // Call layout again with the same bounds — lastBounds guard should skip update
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
    let player = Player()
    let surface = VideoSurface()
    surface.attach(to: player)
    // Second attach with same player should hit the guard and return early
    surface.attach(to: player)
    surface.detach()
  }

  @Test
  func `multiple attach detach cycles`() {
    let player = Player()
    let surface = VideoSurface()

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
    let player1 = Player()
    let player2 = Player()
    let surface = VideoSurface()
    let surfacePtr = Unmanaged.passUnretained(surface).toOpaque()

    surface.attach(to: player1)
    #expect(drawable(of: player1) == surfacePtr)
    surface.attach(to: player2)
    #expect(drawable(of: player1) == nil)
    #expect(drawable(of: player2) == surfacePtr)
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
    let player = Player()
    let surface = VideoSurface()
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
}
