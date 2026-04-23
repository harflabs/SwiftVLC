@testable import SwiftVLC
import CLibVLC
import Testing

extension Logic {
  struct ABLoopTests {
    @Test(
      arguments: [
        (ABLoopState.none, "none"),
        (.pointASet, "point A set"),
        (.active, "active")
      ] as [(ABLoopState, String)]
    )
    func descriptions(state: ABLoopState, expected: String) {
      #expect(state.description == expected)
    }

    @Test
    func hashable() {
      let set: Set<ABLoopState> = [.none, .pointASet, .active, .none]
      #expect(set.count == 3)
    }

    @Test
    func `Init from C values`() {
      #expect(ABLoopState(from: libvlc_abloop_a) == .pointASet)
      #expect(ABLoopState(from: libvlc_abloop_b) == .active)
      #expect(ABLoopState(from: libvlc_abloop_none) == .none)
    }

    @Test
    func `Is Sendable`() {
      let state: ABLoopState = .active
      let sendable: any Sendable = state
      _ = sendable
    }
  }
}
