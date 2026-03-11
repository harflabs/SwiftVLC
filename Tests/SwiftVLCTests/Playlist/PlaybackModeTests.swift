@testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.logic))
struct PlaybackModeTests {
  @Test(
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
    arguments: [
      (PlaybackMode.default, libvlc_playback_mode_default),
      (.loop, libvlc_playback_mode_loop),
      (.repeat, libvlc_playback_mode_repeat),
    ] as [(PlaybackMode, libvlc_playback_mode_t)]
  )
  func `C values`(mode: PlaybackMode, expected: libvlc_playback_mode_t) {
    #expect(mode.cValue == expected)
  }

  @Test
  func hashable() {
    let set: Set<PlaybackMode> = [.default, .loop, .repeat, .default]
    #expect(set.count == 3)
  }

  @Test
  func `Is Sendable`() {
    let mode: PlaybackMode = .loop
    let sendable: any Sendable = mode
    _ = sendable
  }
}
