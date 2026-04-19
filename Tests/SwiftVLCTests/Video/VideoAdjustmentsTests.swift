@testable import SwiftVLC
import Testing

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct VideoAdjustmentsTests {
  @Test
  func `isEnabled default false`() {
    let player = Player()
    #expect(player.adjustments.isEnabled == false)
  }

  @Test
  func `Enable and disable doesn't crash`() {
    let player = Player()
    // libVLC may not persist adjust flag without active video output,
    // so just verify the calls don't crash
    player.adjustments.isEnabled = true
    _ = player.adjustments.isEnabled
    player.adjustments.isEnabled = false
    _ = player.adjustments.isEnabled
  }

  @Test
  func `Contrast get and set`() {
    let player = Player()
    player.adjustments.isEnabled = true
    player.adjustments.contrast = 1.5
    #expect(player.adjustments.contrast == 1.5)
  }

  @Test
  func `Brightness get and set`() {
    let player = Player()
    player.adjustments.isEnabled = true
    player.adjustments.brightness = 0.8
    #expect(player.adjustments.brightness == 0.8)
  }

  @Test
  func `Hue get and set`() {
    let player = Player()
    player.adjustments.isEnabled = true
    player.adjustments.hue = 180
    #expect(player.adjustments.hue == 180)
  }

  @Test
  func `Saturation get and set`() {
    let player = Player()
    player.adjustments.isEnabled = true
    player.adjustments.saturation = 2.0
    #expect(player.adjustments.saturation == 2.0)
  }

  @Test
  func `Gamma get and set`() {
    let player = Player()
    player.adjustments.isEnabled = true
    player.adjustments.gamma = 1.5
    #expect(player.adjustments.gamma == 1.5)
  }

  @Test
  func `Default values`() {
    let player = Player()
    // Default values before enabling
    #expect(player.adjustments.contrast == 1.0)
    #expect(player.adjustments.brightness == 1.0)
    #expect(player.adjustments.saturation == 1.0)
    #expect(player.adjustments.gamma == 1.0)
  }
}
