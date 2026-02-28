@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("PlaybackMode", .tags(.logic))
struct PlaybackModeTests {
  @Test(
    "Descriptions",
    arguments: [
      (PlaybackMode.default, "default"),
      (.loop, "loop"),
      (.repeat, "repeat")
    ] as [(PlaybackMode, String)]
  )
  func descriptions(mode: PlaybackMode, expected: String) {
    #expect(mode.description == expected)
  }

  @Test(
    "C values",
    arguments: [
      (PlaybackMode.default, libvlc_playback_mode_default),
      (.loop, libvlc_playback_mode_loop),
      (.repeat, libvlc_playback_mode_repeat),
    ] as [(PlaybackMode, libvlc_playback_mode_t)]
  )
  func cValues(mode: PlaybackMode, expected: libvlc_playback_mode_t) {
    #expect(mode.cValue == expected)
  }

  @Test("Hashable")
  func hashable() {
    let set: Set<PlaybackMode> = [.default, .loop, .repeat, .default]
    #expect(set.count == 3)
  }

  @Test("Is Sendable")
  func isSendable() {
    let mode: PlaybackMode = .loop
    let sendable: any Sendable = mode
    _ = sendable
  }
}
