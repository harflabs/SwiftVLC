@testable import SwiftVLC
import Testing

extension Logic {
  struct OverlayPositionTests {
    // MARK: - Raw value mapping

    @Test func `center is the empty option set`() {
      #expect(OverlayPosition.center.rawValue == 0)
      #expect(OverlayPosition.center.isEmpty)
    }

    @Test(
      arguments: [
        (OverlayPosition.left, 1),
        (.right, 2),
        (.top, 4),
        (.bottom, 8)
      ] as [(OverlayPosition, Int)]
    )
    func `single edge flags map to libVLC's bitmask`(
      position: OverlayPosition,
      expected: Int
    ) {
      #expect(position.rawValue == expected)
    }

    @Test(
      arguments: [
        (OverlayPosition.topLeft, 5), // 4 | 1
        (.topRight, 6), // 4 | 2
        (.bottomLeft, 9), // 8 | 1
        (.bottomRight, 10) // 8 | 2
      ] as [(OverlayPosition, Int)]
    )
    func `corner combinations match libVLC's bitmask`(
      position: OverlayPosition,
      expected: Int
    ) {
      #expect(position.rawValue == expected)
    }

    // MARK: - OptionSet semantics

    @Test func `combining flags with set syntax works`() {
      let custom: OverlayPosition = [.top, .left]
      #expect(custom == .topLeft)
      #expect(custom.contains(.top))
      #expect(custom.contains(.left))
      #expect(!custom.contains(.bottom))
    }

    @Test func `union and intersection follow OptionSet rules`() {
      let topRow: OverlayPosition = [.top, .left, .right]
      #expect(topRow.intersection(.topLeft) == .topLeft)
      #expect(OverlayPosition.topLeft.union(.bottomRight).rawValue == 15)
    }

    // MARK: - Round-trip via Int

    @Test func `init rawValue round-trips Int bitmasks`() {
      for raw in [0, 1, 2, 4, 5, 6, 8, 9, 10] {
        let pos = OverlayPosition(rawValue: raw)
        #expect(pos.rawValue == raw)
      }
    }

    @Test func `Hashable and Equatable conformances work`() {
      let a: OverlayPosition = .topLeft
      let b: OverlayPosition = [.top, .left]
      #expect(a == b)
      #expect(Set([a, b, .bottomRight]).count == 2)
    }
  }
}
