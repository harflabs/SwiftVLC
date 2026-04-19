@testable import SwiftVLC
import Testing

@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct AspectRatioTests {
  @Test(
    arguments: [
      (AspectRatio.default, "default"),
      (.ratio(16, 9), "16:9"),
      (.ratio(4, 3), "4:3"),
      (.fill, "fill")
    ] as [(AspectRatio, String)]
  )
  func descriptions(ratio: AspectRatio, expected: String) {
    #expect(ratio.description == expected)
  }

  @Test
  func `vlcString nil for default and fill`() {
    #expect(AspectRatio.default.vlcString == nil)
    #expect(AspectRatio.fill.vlcString == nil)
  }

  @Test(
    arguments: [
      (AspectRatio.ratio(16, 9), "16:9"),
      (.ratio(4, 3), "4:3"),
      (.ratio(21, 9), "21:9"),
    ] as [(AspectRatio, String)]
  )
  func `vlcString for ratios`(ratio: AspectRatio, expected: String) {
    #expect(ratio.vlcString == expected)
  }

  @Test
  func hashable() {
    let set: Set<AspectRatio> = [.default, .ratio(16, 9), .fill, .default]
    #expect(set.count == 3)
  }

  @Test
  func `Common ratios`() {
    // Just verify these don't crash
    let ratios: [AspectRatio] = [.default, .ratio(16, 9), .ratio(4, 3), .ratio(21, 9), .fill]
    #expect(ratios.count == 5)
  }

  @Test
  func `Ratio equality`() {
    #expect(AspectRatio.ratio(16, 9) == .ratio(16, 9))
    #expect(AspectRatio.ratio(16, 9) != .ratio(4, 3))
    #expect(AspectRatio.default != .fill)
  }
}
