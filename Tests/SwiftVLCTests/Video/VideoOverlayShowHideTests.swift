@testable import SwiftVLC
import Testing

/// Covers the `show(...)` / `hide()` convenience APIs on `Marquee` and
/// `Logo`, which are the recommended entry points in the DocC but were
/// untested by the existing suites (which only exercised individual
/// property setters).
///
/// All `player.marquee` / `player.logo` accesses go through the
/// `withMarquee` / `withLogo` scoped closures because the `#expect`
/// macro auto-captures expressions into its diagnostic tree — and
/// the overlay structs are `~Copyable, ~Escapable`, so they can't be
/// held by the macro machinery.
@Suite(.tags(.integration, .mainActor))
@MainActor
struct VideoOverlayShowHideTests {
  // MARK: - Marquee.show

  @Test
  func `Marquee show enables the filter and stores the style`() {
    let player = Player(instance: TestInstance.shared)

    player.marquee.show(
      text: "LIVE",
      fontSize: 32,
      color: 0xFF0000,
      opacity: 255,
      position: 4, // top
      timeout: 5000
    )

    let snapshot = player.withMarquee { marquee in
      (
        enabled: marquee.isEnabled,
        fontSize: marquee.fontSize,
        color: marquee.color,
        opacity: marquee.opacity,
        position: marquee.position,
        timeout: marquee.timeout
      )
    }

    #expect(snapshot.enabled)
    #expect(snapshot.fontSize == 32)
    #expect(snapshot.color == 0xFF0000)
    #expect(snapshot.opacity == 255)
    #expect(snapshot.position == 4)
    #expect(snapshot.timeout == 5000)
  }

  /// `show()` called twice in a row must re-enable the filter cleanly
  /// (the implementation flips `Enable` off→on to flush cached state).
  @Test
  func `Marquee show called twice leaves filter enabled`() {
    let player = Player(instance: TestInstance.shared)

    player.marquee.show(text: "first")
    player.marquee.show(text: "second", fontSize: 18, color: 0x00FF00)

    let snapshot = player.withMarquee { marquee in
      (enabled: marquee.isEnabled, fontSize: marquee.fontSize, color: marquee.color)
    }
    #expect(snapshot.enabled)
    #expect(snapshot.fontSize == 18)
    #expect(snapshot.color == 0x00FF00)
  }

  /// `hide()` is a thin wrapper over `isEnabled = false`; pin it so a
  /// future refactor can't accidentally flip semantics.
  @Test
  func `Marquee hide disables the filter`() {
    let player = Player(instance: TestInstance.shared)
    player.marquee.show(text: "hello")
    let enabledBefore = player.withMarquee { $0.isEnabled }
    #expect(enabledBefore)

    player.marquee.hide()
    let enabledAfter = player.withMarquee { $0.isEnabled }
    #expect(enabledAfter == false)
  }

  // MARK: - Logo.show

  @Test
  func `Logo show enables filter with opacity and position`() {
    let player = Player(instance: TestInstance.shared)

    player.logo.show(file: "/tmp/does-not-matter.png", opacity: 200, position: 4)

    let snapshot = player.withLogo { logo in
      (enabled: logo.isEnabled, opacity: logo.opacity, position: logo.position)
    }
    #expect(snapshot.enabled)
    #expect(snapshot.opacity == 200)
    #expect(snapshot.position == 4)
  }

  @Test
  func `Logo hide disables the filter`() {
    let player = Player(instance: TestInstance.shared)
    player.logo.show(file: "/tmp/x.png")
    let enabledBefore = player.withLogo { $0.isEnabled }
    #expect(enabledBefore)

    player.logo.hide()
    let enabledAfter = player.withLogo { $0.isEnabled }
    #expect(enabledAfter == false)
  }
}
