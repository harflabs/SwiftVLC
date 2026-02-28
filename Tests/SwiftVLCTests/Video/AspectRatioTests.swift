@testable import SwiftVLC
import Testing

@Suite("AspectRatio", .tags(.logic))
struct AspectRatioTests {
  @Test(
    "Descriptions",
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

  @Test("vlcString nil for default and fill")
  func vlcStringNilForDefaultAndFill() {
    #expect(AspectRatio.default.vlcString == nil)
    #expect(AspectRatio.fill.vlcString == nil)
  }

  @Test(
    "vlcString for ratios",
    arguments: [
      (AspectRatio.ratio(16, 9), "16:9"),
      (.ratio(4, 3), "4:3"),
      (.ratio(21, 9), "21:9"),
    ] as [(AspectRatio, String)]
  )
  func vlcStringForRatios(ratio: AspectRatio, expected: String) {
    #expect(ratio.vlcString == expected)
  }

  @Test("Hashable")
  func hashable() {
    let set: Set<AspectRatio> = [.default, .ratio(16, 9), .fill, .default]
    #expect(set.count == 3)
  }

  @Test("Common ratios")
  func commonRatios() {
    // Just verify these don't crash
    let ratios: [AspectRatio] = [.default, .ratio(16, 9), .ratio(4, 3), .ratio(21, 9), .fill]
    #expect(ratios.count == 5)
  }

  @Test("Ratio equality")
  func ratioEquality() {
    #expect(AspectRatio.ratio(16, 9) == .ratio(16, 9))
    #expect(AspectRatio.ratio(16, 9) != .ratio(4, 3))
    #expect(AspectRatio.default != .fill)
  }
}
