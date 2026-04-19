@testable import SwiftVLC
import Testing

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct MarqueeTests {
  @Test
  func `isEnabled default`() {
    let player = Player()
    #expect(player.marquee.isEnabled == false)
  }

  @Test
  func `Enable and disable`() {
    let player = Player()
    player.marquee.isEnabled = true
    #expect(player.marquee.isEnabled == true)
    player.marquee.isEnabled = false
    #expect(player.marquee.isEnabled == false)
  }

  @Test
  func `Text set`() {
    let player = Player()
    // setText is write-only — libVLC does not expose a getter. Just verify
    // the call is accepted without crashing.
    player.marquee.setText("Hello World")
  }

  @Test
  func `Color get and set`() {
    let player = Player()
    player.marquee.color = 0xFF0000
    #expect(player.marquee.color == 0xFF0000)
  }

  @Test
  func `Opacity get and set`() {
    let player = Player()
    player.marquee.opacity = 128
    #expect(player.marquee.opacity == 128)
  }

  @Test
  func `Font size get and set`() {
    let player = Player()
    player.marquee.fontSize = 24
    #expect(player.marquee.fontSize == 24)
  }

  @Test
  func `X get and set`() {
    let player = Player()
    player.marquee.x = 100
    #expect(player.marquee.x == 100)
  }

  @Test
  func `Y get and set`() {
    let player = Player()
    player.marquee.y = 50
    #expect(player.marquee.y == 50)
  }

  @Test
  func `Timeout get and set`() {
    let player = Player()
    player.marquee.timeout = 5000
    #expect(player.marquee.timeout == 5000)
  }

  @Test
  func `Refresh get and set`() {
    let player = Player()
    player.marquee.refresh = 1000
    #expect(player.marquee.refresh == 1000)
  }

  @Test
  func `Position get and set`() {
    let player = Player()
    player.marquee.position = 8 // bottom
    #expect(player.marquee.position == 8)
  }
}
