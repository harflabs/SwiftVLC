@testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct PlayerStateTests {
  @Test(
    arguments: [
      (PlayerState.idle, "idle"),
      (.opening, "opening"),
      (.buffering, "buffering"),
      (.playing, "playing"),
      (.paused, "paused"),
      (.stopped, "stopped"),
      (.stopping, "stopping"),
      (.error, "error")
    ] as [(PlayerState, String)]
  )
  func descriptions(state: PlayerState, expected: String) {
    #expect(state.description == expected)
  }

  @Test
  func hashable() {
    let set: Set<PlayerState> = [.idle, .playing, .paused, .idle, .buffering, .buffering]
    #expect(set.count == 4)
  }

  @Test
  func `Init from C state`() {
    #expect(PlayerState(from: libvlc_NothingSpecial) == .idle)
    #expect(PlayerState(from: libvlc_Opening) == .opening)
    #expect(PlayerState(from: libvlc_Buffering) == .buffering)
    #expect(PlayerState(from: libvlc_Playing) == .playing)
    #expect(PlayerState(from: libvlc_Paused) == .paused)
    #expect(PlayerState(from: libvlc_Stopped) == .stopped)
    #expect(PlayerState(from: libvlc_Stopping) == .stopping)
    #expect(PlayerState(from: libvlc_Error) == .error)
  }

  @Test
  func `Init from unknown C state defaults to idle`() {
    let state = PlayerState(from: libvlc_state_t(rawValue: 999))
    #expect(state == .idle)
  }

  @Test
  func `Is Sendable`() {
    let state: PlayerState = .playing
    let sendable: any Sendable = state
    _ = sendable
  }
}
