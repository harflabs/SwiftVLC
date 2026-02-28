@testable import SwiftVLC
import Testing

@Suite("Marquee", .tags(.integration, .mainActor), .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarqueeTests {
  @Test("isEnabled default")
  func isEnabledDefault() throws {
    let player = try Player()
    #expect(player.marquee.isEnabled == false)
  }

  @Test("Enable and disable")
  func enableDisable() throws {
    let player = try Player()
    player.marquee.isEnabled = true
    #expect(player.marquee.isEnabled == true)
    player.marquee.isEnabled = false
    #expect(player.marquee.isEnabled == false)
  }

  @Test("Text set")
  func textSet() throws {
    let player = try Player()
    player.marquee.text = "Hello World"
    // text getter always returns "" (write-only)
    #expect(player.marquee.text == "")
  }

  @Test("Color get and set")
  func colorGetSet() throws {
    let player = try Player()
    player.marquee.color = 0xFF0000
    #expect(player.marquee.color == 0xFF0000)
  }

  @Test("Opacity get and set")
  func opacityGetSet() throws {
    let player = try Player()
    player.marquee.opacity = 128
    #expect(player.marquee.opacity == 128)
  }

  @Test("Font size get and set")
  func fontSizeGetSet() throws {
    let player = try Player()
    player.marquee.fontSize = 24
    #expect(player.marquee.fontSize == 24)
  }

  @Test("X get and set")
  func xGetSet() throws {
    let player = try Player()
    player.marquee.x = 100
    #expect(player.marquee.x == 100)
  }

  @Test("Y get and set")
  func yGetSet() throws {
    let player = try Player()
    player.marquee.y = 50
    #expect(player.marquee.y == 50)
  }

  @Test("Timeout get and set")
  func timeoutGetSet() throws {
    let player = try Player()
    player.marquee.timeout = 5000
    #expect(player.marquee.timeout == 5000)
  }

  @Test("Refresh get and set")
  func refreshGetSet() throws {
    let player = try Player()
    player.marquee.refresh = 1000
    #expect(player.marquee.refresh == 1000)
  }

  @Test("Position get and set")
  func positionGetSet() throws {
    let player = try Player()
    player.marquee.position = 8 // bottom
    #expect(player.marquee.position == 8)
  }
}
