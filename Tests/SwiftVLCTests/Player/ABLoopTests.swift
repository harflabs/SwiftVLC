@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("ABLoopState", .tags(.logic))
struct ABLoopTests {
  @Test(
    "Descriptions",
    arguments: [
      (ABLoopState.none, "none"),
      (.pointASet, "point A set"),
      (.active, "active")
    ] as [(ABLoopState, String)]
  )
  func descriptions(state: ABLoopState, expected: String) {
    #expect(state.description == expected)
  }

  @Test("Hashable")
  func hashable() {
    let set: Set<ABLoopState> = [.none, .pointASet, .active, .none]
    #expect(set.count == 3)
  }

  @Test("Init from C values")
  func initFromCValues() {
    #expect(ABLoopState(from: libvlc_abloop_a) == .pointASet)
    #expect(ABLoopState(from: libvlc_abloop_b) == .active)
    #expect(ABLoopState(from: libvlc_abloop_none) == .none)
  }

  @Test("Is Sendable")
  func isSendable() {
    let state: ABLoopState = .active
    let sendable: any Sendable = state
    _ = sendable
  }
}
