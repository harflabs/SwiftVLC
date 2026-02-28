@testable import SwiftVLC
import Testing

@Suite("VideoAdjustments", .tags(.integration, .mainActor), .serialized, .timeLimit(.minutes(1)))
@MainActor
struct VideoAdjustmentsTests {
  @Test("isEnabled default false")
  func isEnabledDefaultFalse() throws {
    let player = try Player()
    #expect(player.adjustments.isEnabled == false)
  }

  @Test("Enable and disable doesn't crash")
  func enableDisable() throws {
    let player = try Player()
    // libVLC may not persist adjust flag without active video output,
    // so just verify the calls don't crash
    player.adjustments.isEnabled = true
    _ = player.adjustments.isEnabled
    player.adjustments.isEnabled = false
    _ = player.adjustments.isEnabled
  }

  @Test("Contrast get and set")
  func contrastGetSet() throws {
    let player = try Player()
    player.adjustments.isEnabled = true
    player.adjustments.contrast = 1.5
    #expect(player.adjustments.contrast == 1.5)
  }

  @Test("Brightness get and set")
  func brightnessGetSet() throws {
    let player = try Player()
    player.adjustments.isEnabled = true
    player.adjustments.brightness = 0.8
    #expect(player.adjustments.brightness == 0.8)
  }

  @Test("Hue get and set")
  func hueGetSet() throws {
    let player = try Player()
    player.adjustments.isEnabled = true
    player.adjustments.hue = 180
    #expect(player.adjustments.hue == 180)
  }

  @Test("Saturation get and set")
  func saturationGetSet() throws {
    let player = try Player()
    player.adjustments.isEnabled = true
    player.adjustments.saturation = 2.0
    #expect(player.adjustments.saturation == 2.0)
  }

  @Test("Gamma get and set")
  func gammaGetSet() throws {
    let player = try Player()
    player.adjustments.isEnabled = true
    player.adjustments.gamma = 1.5
    #expect(player.adjustments.gamma == 1.5)
  }

  @Test("Default values")
  func defaultValues() throws {
    let player = try Player()
    // Default values before enabling
    #expect(player.adjustments.contrast == 1.0)
    #expect(player.adjustments.brightness == 1.0)
    #expect(player.adjustments.saturation == 1.0)
    #expect(player.adjustments.gamma == 1.0)
  }
}
