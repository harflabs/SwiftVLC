@testable import SwiftVLC
import Testing

@Suite("Logo", .tags(.integration, .mainActor), .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LogoTests {
  @Test("isEnabled default")
  func isEnabledDefault() throws {
    let player = try Player()
    #expect(player.logo.isEnabled == false)
  }

  @Test("Enable and disable")
  func enableDisable() throws {
    let player = try Player()
    player.logo.isEnabled = true
    #expect(player.logo.isEnabled == true)
    player.logo.isEnabled = false
    #expect(player.logo.isEnabled == false)
  }

  @Test("File set")
  func fileSet() throws {
    let player = try Player()
    player.logo.file = "/tmp/logo.png"
    // file getter always returns "" (write-only)
    #expect(player.logo.file == "")
  }

  @Test("X get and set")
  func xGetSet() throws {
    let player = try Player()
    player.logo.x = 10
    #expect(player.logo.x == 10)
  }

  @Test("Y get and set")
  func yGetSet() throws {
    let player = try Player()
    player.logo.y = 20
    #expect(player.logo.y == 20)
  }

  @Test("Opacity get and set")
  func opacityGetSet() throws {
    let player = try Player()
    player.logo.opacity = 200
    #expect(player.logo.opacity == 200)
  }

  @Test("Delay get and set")
  func delayGetSet() throws {
    let player = try Player()
    player.logo.delay = 1000
    #expect(player.logo.delay == 1000)
  }

  @Test("Repeat count get and set")
  func repeatCountGetSet() throws {
    let player = try Player()
    player.logo.repeatCount = -1
    #expect(player.logo.repeatCount == -1)
  }

  @Test("Position get and set")
  func positionGetSet() throws {
    let player = try Player()
    player.logo.position = 5 // top+left
    #expect(player.logo.position == 5)
  }
}
