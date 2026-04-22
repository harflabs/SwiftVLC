@testable import SwiftVLC
import Testing

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct VideoViewTests {
  @Test
  func `VideoSurface can be created`() {
    let surface = VideoSurface()
    #if canImport(AppKit)
    #expect(surface is NSView)
    #elseif canImport(UIKit)
    #expect(surface is UIView)
    #endif
  }

  @Test
  func `attach to player does not crash`() {
    let player = Player(instance: TestInstance.shared)
    let surface = VideoSurface()
    surface.attach(to: player)
  }

  @Test
  func `detach does not crash`() {
    let player = Player(instance: TestInstance.shared)
    let surface = VideoSurface()
    surface.attach(to: player)
    surface.detach()
  }

  @Test
  func `attach twice with same player is idempotent`() {
    let player = Player(instance: TestInstance.shared)
    let surface = VideoSurface()
    surface.attach(to: player)
    surface.attach(to: player)
    // No crash means the guard clause worked correctly
  }

  @Test
  func `detach without prior attach does not crash`() {
    let surface = VideoSurface()
    surface.detach()
  }

  @Test
  func `attach then detach lifecycle`() {
    let player = Player(instance: TestInstance.shared)
    let surface = VideoSurface()
    surface.attach(to: player)
    surface.detach()
    // Player should still be usable after detach
    #expect(player.state == .idle)
  }

  @Test
  func `VideoSurface with non-zero bounds triggers layout`() {
    let player = Player(instance: TestInstance.shared)
    let surface = VideoSurface()
    surface.attach(to: player)

    #if canImport(AppKit)
    surface.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
    surface.layout()
    #elseif canImport(UIKit)
    surface.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
    surface.layoutSubviews()
    #endif
  }
}
