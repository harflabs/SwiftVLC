@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct MarqueeTests {
    @Test
    func `isEnabled default`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.marquee.isEnabled == false)
    }

    @Test
    func `Enable and disable`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.isEnabled = true
      #expect(player.marquee.isEnabled == true)
      player.marquee.isEnabled = false
      #expect(player.marquee.isEnabled == false)
    }

    @Test
    func `Text set`() {
      let player = Player(instance: TestInstance.shared)
      // setText is write-only — libVLC does not expose a getter. Just verify
      // the call is accepted without crashing.
      player.marquee.setText("Hello World")
    }

    @Test
    func `Color get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.color = 0xFF0000
      #expect(player.marquee.color == 0xFF0000)
    }

    @Test
    func `Opacity get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.opacity = 128
      #expect(player.marquee.opacity == 128)
    }

    @Test
    func `Font size get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.fontSize = 24
      #expect(player.marquee.fontSize == 24)
    }

    @Test
    func `X get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.x = 100
      #expect(player.marquee.x == 100)
    }

    @Test
    func `Y get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.y = 50
      #expect(player.marquee.y == 50)
    }

    @Test
    func `Timeout get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.timeout = 5000
      #expect(player.marquee.timeout == 5000)
    }

    @Test
    func `Refresh get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.refresh = 1000
      #expect(player.marquee.refresh == 1000)
    }

    @Test
    func `Position get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.position = 8 // bottom
      #expect(player.marquee.position == 8)
    }

    @Test
    func `screenPosition typed accessor round-trips`() {
      let player = Player(instance: TestInstance.shared)
      player.marquee.screenPosition = .bottomRight
      #expect(player.marquee.screenPosition == .bottomRight)
      #expect(player.marquee.position == 10)

      player.marquee.screenPosition = [.top]
      #expect(player.marquee.screenPosition == .top)
      #expect(player.marquee.position == 4)

      player.marquee.screenPosition = .center
      #expect(player.marquee.position == 0)
    }

    /// Each style write cancels any pending restore task and schedules
    /// a fresh one, so rapid mutations coalesce into a single restore
    /// instead of queuing an unbounded number of in-flight tasks. We
    /// verify by performing 100 rapid style writes interleaved with
    /// text changes and checking that:
    ///   1. No crash, no double-restore, no leaked task accumulation
    ///   2. After the dust settles, `_marqueeText` matches the final
    ///      explicit `setText` call.
    @Test
    func `Rapid style writes coalesce into a single restore`() async {
      let player = Player(instance: TestInstance.shared)
      player.marquee.isEnabled = true

      for i in 0..<100 {
        player.marquee.setText("text \(i)")
        player.marquee.color = i % 2 == 0 ? 0xFF0000 : 0x00FF00
        player.marquee.opacity = (i * 7) % 256
        player.marquee.fontSize = 12 + (i % 24)
      }

      player.marquee.setText("final")

      // Wait past the 50ms restore window plus a margin.
      try? await Task.sleep(for: .milliseconds(150))

      #expect(player._marqueeText == "final")
      #expect(player._marqueeRestoreTask == nil)
    }

    /// Regression test: disabling the marquee while a restore task is
    /// pending must not crash and must leave the player in a consistent
    /// state.
    @Test
    func `Disable during pending restore is safe`() async {
      let player = Player(instance: TestInstance.shared)
      player.marquee.isEnabled = true
      player.marquee.setText("hello")
      // Schedule a restore by writing a style.
      player.marquee.color = 0xFF0000
      // Disable before the restore fires.
      player.marquee.isEnabled = false

      try? await Task.sleep(for: .milliseconds(150))

      // Restore task either ran (and wrote text into a disabled filter,
      // harmless) or got cancelled by deinit. Either way, no crash.
      #expect(player.marquee.isEnabled == false)
    }
  }
}
