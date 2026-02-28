@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("PlayerState", .tags(.logic))
struct PlayerStateTests {
  @Test(
    "Descriptions",
    arguments: [
      (PlayerState.idle, "idle"),
      (.opening, "opening"),
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

  @Test(
    "Buffering percentage formatting",
    arguments: [
      (Float(0.0), "buffering(0%)"),
      (Float(0.5), "buffering(50%)"),
      (Float(1.0), "buffering(100%)"),
    ] as [(Float, String)]
  )
  func bufferingPercentageFormatting(pct: Float, expected: String) {
    #expect(PlayerState.buffering(pct).description == expected)
  }

  @Test("Hashable")
  func hashable() {
    let set: Set<PlayerState> = [.idle, .playing, .paused, .idle]
    #expect(set.count == 3)
  }

  @Test("Buffering hashability")
  func bufferingHashability() {
    let a = PlayerState.buffering(0.5)
    let b = PlayerState.buffering(0.5)
    let c = PlayerState.buffering(0.7)
    #expect(a == b)
    #expect(a != c)
  }

  @Test("Init from C state")
  func initFromCState() {
    #expect(PlayerState(from: libvlc_NothingSpecial) == .idle)
    #expect(PlayerState(from: libvlc_Opening) == .opening)
    #expect(PlayerState(from: libvlc_Playing) == .playing)
    #expect(PlayerState(from: libvlc_Paused) == .paused)
    #expect(PlayerState(from: libvlc_Stopped) == .stopped)
    #expect(PlayerState(from: libvlc_Stopping) == .stopping)
    #expect(PlayerState(from: libvlc_Error) == .error)
  }

  @Test("Init from C Buffering state")
  func initFromCBufferingState() {
    let state = PlayerState(from: libvlc_Buffering)
    #expect(state == .buffering(0))
  }

  @Test("Init from unknown C state defaults to idle")
  func initFromUnknownCState() {
    let state = PlayerState(from: libvlc_state_t(rawValue: 999))
    #expect(state == .idle)
  }

  @Test("Is Sendable")
  func isSendable() {
    let state: PlayerState = .playing
    let sendable: any Sendable = state
    _ = sendable
  }
}
