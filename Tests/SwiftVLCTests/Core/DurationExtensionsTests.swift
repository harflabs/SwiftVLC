@testable import SwiftVLC
import Testing

@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct DurationExtensionsTests {
  @Test(
    arguments: [
      (Duration.seconds(1), Int64(1000)),
      (.seconds(0), Int64(0)),
      (.milliseconds(500), Int64(500)),
      (.seconds(60), Int64(60000)),
      (.milliseconds(1), Int64(1))
    ] as [(Duration, Int64)]
  )
  func `Milliseconds conversion`(duration: Duration, expected: Int64) {
    #expect(duration.milliseconds == expected)
  }

  @Test(
    arguments: [
      (Duration.seconds(1), Int64(1_000_000)),
      (.milliseconds(1), Int64(1000)),
      (.microseconds(1), Int64(1)),
    ] as [(Duration, Int64)]
  )
  func `Microseconds conversion`(duration: Duration, expected: Int64) {
    #expect(duration.microseconds == expected)
  }

  @Test(
    arguments: [
      (Duration.seconds(65), "1:05"),
      (.seconds(600), "10:00"),
      (.seconds(0), "0:00"),
      (.seconds(59), "0:59"),
      (.seconds(3599), "59:59"),
    ] as [(Duration, String)]
  )
  func `Formatted minutes and seconds`(duration: Duration, expected: String) {
    #expect(duration.formatted == expected)
  }

  @Test
  func `Formatted hours minutes seconds`() {
    #expect(Duration.seconds(3661).formatted == "1:01:01")
  }

  @Test
  func `Formatted zero duration`() {
    #expect(Duration.zero.formatted == "0:00")
  }

  @Test
  func `Formatted negative duration`() {
    #expect(Duration.seconds(-5).formatted == "-0:05")
  }

  @Test
  func `Formatted sub-second duration`() {
    #expect(Duration.milliseconds(500).formatted == "0:00")
  }

  @Test(
    arguments: [Int64(0), 1, 500, 1000, 60000, 123_456] as [Int64]
  )
  func `Milliseconds round-trip`(ms: Int64) {
    #expect(Duration.milliseconds(ms).milliseconds == ms)
  }

  @Test(
    arguments: [Int64(0), 1, 1000, 1_000_000] as [Int64]
  )
  func `Microseconds round-trip`(us: Int64) {
    #expect(Duration.microseconds(us).microseconds == us)
  }

  @Test
  func `Formatted large duration`() {
    #expect(Duration.seconds(86400).formatted == "24:00:00")
  }
}
