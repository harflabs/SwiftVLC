@testable import SwiftVLC
import Testing

@Suite(.tags(.integration, .mainActor))
@MainActor
struct VideoOverlayBatchTests {
  // MARK: - withAdjustments batch

  @Test
  func `withAdjustments sets multiple properties in one scoped call`() {
    let player = Player()
    player.withAdjustments { adj in
      adj.contrast = 1.5
      adj.brightness = 0.7
      adj.hue = 90
      adj.saturation = 2.5
      adj.gamma = 0.5
    }
    #expect(player.adjustments.contrast == 1.5)
    #expect(player.adjustments.brightness == 0.7)
    #expect(player.adjustments.hue == 90)
    #expect(player.adjustments.saturation == 2.5)
    #expect(player.adjustments.gamma == 0.5)
  }

  @Test
  func `withAdjustments returns a value`() {
    let player = Player()
    let contrast = player.withAdjustments { adj -> Float in
      adj.contrast = 1.8
      return adj.contrast
    }
    #expect(contrast == 1.8)
  }

  // MARK: - withMarquee batch

  @Test
  func `withMarquee sets multiple properties in one scoped call`() {
    let player = Player()
    player.withMarquee { m in
      m.isEnabled = true
      m.setText("Batch Test")
      m.color = 0x00FF00
      m.opacity = 200
      m.fontSize = 32
      m.x = 50
      m.y = 75
      m.timeout = 3000
      m.position = 9 // bottom + left
    }
    #expect(player.marquee.isEnabled == true)
    #expect(player.marquee.color == 0x00FF00)
    #expect(player.marquee.opacity == 200)
    #expect(player.marquee.fontSize == 32)
    #expect(player.marquee.x == 50)
    #expect(player.marquee.y == 75)
    #expect(player.marquee.timeout == 3000)
    #expect(player.marquee.position == 9)
  }

  @Test
  func `withMarquee returns a value`() {
    let player = Player()
    let opacity = player.withMarquee { m -> Int in
      m.opacity = 180
      return m.opacity
    }
    #expect(opacity == 180)
  }

  // MARK: - withLogo batch

  @Test
  func `withLogo sets multiple properties in one scoped call`() {
    let player = Player()
    player.withLogo { l in
      l.isEnabled = true
      l.setFile("/tmp/test-logo.png")
      l.x = 30
      l.y = 40
      l.opacity = 150
      l.delay = 2000
      l.repeatCount = 3
      l.position = 6 // top + right
    }
    #expect(player.logo.isEnabled == true)
    #expect(player.logo.x == 30)
    #expect(player.logo.y == 40)
    #expect(player.logo.opacity == 150)
    #expect(player.logo.delay == 2000)
    #expect(player.logo.repeatCount == 3)
    #expect(player.logo.position == 6)
  }

  @Test
  func `withLogo returns a value`() {
    let player = Player()
    let pos = player.withLogo { l -> Int in
      l.position = 5
      return l.position
    }
    #expect(pos == 5)
  }

  // MARK: - Persistence across accessor calls

  @Test
  func `adjustments persist across multiple accessor calls`() {
    let player = Player()
    player.adjustments.isEnabled = true
    player.adjustments.contrast = 1.3
    player.adjustments.brightness = 0.9
    // Read back through a separate accessor access
    #expect(player.adjustments.contrast == 1.3)
    #expect(player.adjustments.brightness == 0.9)
    // Modify one, verify the other is unchanged
    player.adjustments.contrast = 1.7
    #expect(player.adjustments.contrast == 1.7)
    #expect(player.adjustments.brightness == 0.9)
  }

  // MARK: - Write-only properties

  @Test
  func `marquee setText does not crash`() {
    let player = Player()
    // Write-only: libVLC exposes no getter. Just verify calls are accepted.
    player.marquee.setText("")
    player.marquee.setText("Some text")
  }

  @Test
  func `logo setFile does not crash`() {
    let player = Player()
    // Write-only: libVLC exposes no getter. Just verify calls are accepted.
    player.logo.setFile("")
    player.logo.setFile("/tmp/logo.png")
  }

  // MARK: - Multiple sequential withAdjustments calls compound

  @Test
  func `multiple sequential withAdjustments calls compound correctly`() {
    let player = Player()
    player.withAdjustments { adj in
      adj.isEnabled = true
      adj.contrast = 1.2
      adj.brightness = 0.8
    }
    player.withAdjustments { adj in
      adj.saturation = 2.0
      adj.gamma = 0.5
    }
    // All values from both calls should persist
    #expect(player.adjustments.contrast == 1.2)
    #expect(player.adjustments.brightness == 0.8)
    #expect(player.adjustments.saturation == 2.0)
    #expect(player.adjustments.gamma == 0.5)
  }

  // MARK: - Enable then disable adjustments

  @Test
  func `enabling then disabling adjustments does not crash`() {
    let player = Player()
    // isEnabled may not persist without active video output,
    // but the calls should not crash
    player.adjustments.isEnabled = true
    player.adjustments.contrast = 1.5
    player.adjustments.isEnabled = false
    // Underlying contrast value should still be stored
    #expect(player.adjustments.contrast == 1.5)
  }

  // MARK: - Default values

  @Test
  func `marquee default values`() {
    let player = Player()
    #expect(player.marquee.isEnabled == false)
    #expect(player.marquee.opacity == 255)
    #expect(player.marquee.x == 0)
    #expect(player.marquee.y == 0)
    #expect(player.marquee.timeout == 0)
  }

  @Test
  func `logo default values`() {
    let player = Player()
    #expect(player.logo.isEnabled == false)
  }

  // MARK: - Extreme ranges

  @Test
  func `adjustment values at extreme ranges`() {
    let player = Player()
    player.adjustments.isEnabled = true

    // Minimum values
    player.adjustments.contrast = 0.0
    #expect(player.adjustments.contrast == 0.0)
    player.adjustments.brightness = 0.0
    #expect(player.adjustments.brightness == 0.0)
    player.adjustments.hue = 0
    #expect(player.adjustments.hue == 0)
    player.adjustments.saturation = 0.0
    #expect(player.adjustments.saturation == 0.0)
    player.adjustments.gamma = 0.01
    #expect(player.adjustments.gamma == Float(0.01))

    // Maximum values
    player.adjustments.contrast = 2.0
    #expect(player.adjustments.contrast == 2.0)
    player.adjustments.brightness = 2.0
    #expect(player.adjustments.brightness == 2.0)
    player.adjustments.hue = 360
    #expect(player.adjustments.hue == 360)
    player.adjustments.saturation = 3.0
    #expect(player.adjustments.saturation == 3.0)
    player.adjustments.gamma = 10.0
    #expect(player.adjustments.gamma == 10.0)
  }

  // MARK: - Opacity boundaries

  @Test
  func `marquee opacity boundaries`() {
    let player = Player()
    player.marquee.opacity = 0
    #expect(player.marquee.opacity == 0)
    player.marquee.opacity = 255
    #expect(player.marquee.opacity == 255)
    player.marquee.opacity = 128
    #expect(player.marquee.opacity == 128)
  }

  @Test
  func `logo opacity boundaries`() {
    let player = Player()
    player.logo.opacity = 0
    #expect(player.logo.opacity == 0)
    player.logo.opacity = 255
    #expect(player.logo.opacity == 255)
    player.logo.opacity = 128
    #expect(player.logo.opacity == 128)
  }

  // MARK: - Position values

  @Test
  func `marquee position values`() {
    let player = Player()

    // center
    player.marquee.position = 0
    #expect(player.marquee.position == 0)

    // left
    player.marquee.position = 1
    #expect(player.marquee.position == 1)

    // right
    player.marquee.position = 2
    #expect(player.marquee.position == 2)

    // top
    player.marquee.position = 4
    #expect(player.marquee.position == 4)

    // bottom
    player.marquee.position = 8
    #expect(player.marquee.position == 8)

    // top-left
    player.marquee.position = 5
    #expect(player.marquee.position == 5)

    // top-right
    player.marquee.position = 6
    #expect(player.marquee.position == 6)

    // bottom-left
    player.marquee.position = 9
    #expect(player.marquee.position == 9)

    // bottom-right
    player.marquee.position = 10
    #expect(player.marquee.position == 10)
  }

  @Test
  func `logo position values`() {
    let player = Player()

    // center
    player.logo.position = 0
    #expect(player.logo.position == 0)

    // left
    player.logo.position = 1
    #expect(player.logo.position == 1)

    // right
    player.logo.position = 2
    #expect(player.logo.position == 2)

    // top
    player.logo.position = 4
    #expect(player.logo.position == 4)

    // bottom
    player.logo.position = 8
    #expect(player.logo.position == 8)

    // top-left
    player.logo.position = 5
    #expect(player.logo.position == 5)

    // top-right
    player.logo.position = 6
    #expect(player.logo.position == 6)

    // bottom-left
    player.logo.position = 9
    #expect(player.logo.position == 9)

    // bottom-right
    player.logo.position = 10
    #expect(player.logo.position == 10)
  }
}
