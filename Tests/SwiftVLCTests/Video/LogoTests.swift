@testable import SwiftVLC
import Testing

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct LogoTests {
  @Test
  func `isEnabled default`() {
    let player = Player(instance: TestInstance.shared)
    #expect(player.logo.isEnabled == false)
  }

  @Test
  func `Enable and disable`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.isEnabled = true
    #expect(player.logo.isEnabled == true)
    player.logo.isEnabled = false
    #expect(player.logo.isEnabled == false)
  }

  @Test
  func `File set`() {
    let player = Player(instance: TestInstance.shared)
    // setFile is write-only — libVLC does not expose a getter. Just verify
    // the call is accepted without crashing.
    player.logo.setFile("/tmp/logo.png")
  }

  @Test
  func `X get and set`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.x = 10
    #expect(player.logo.x == 10)
  }

  @Test
  func `Y get and set`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.y = 20
    #expect(player.logo.y == 20)
  }

  @Test
  func `Opacity get and set`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.opacity = 200
    #expect(player.logo.opacity == 200)
  }

  @Test
  func `Delay get and set`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.delay = 1000
    #expect(player.logo.delay == 1000)
  }

  @Test
  func `Repeat count get and set`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.repeatCount = -1
    #expect(player.logo.repeatCount == -1)
  }

  @Test
  func `Position get and set`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.position = 5 // top+left
    #expect(player.logo.position == 5)
  }
}
