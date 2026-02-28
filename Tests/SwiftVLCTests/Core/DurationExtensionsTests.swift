@testable import SwiftVLC
import Testing

@Suite("Duration+Extensions", .tags(.logic))
struct DurationExtensionsTests {
  @Test(
    "Milliseconds conversion",
    arguments: [
      (Duration.seconds(1), Int64(1000)),
      (.seconds(0), Int64(0)),
      (.milliseconds(500), Int64(500)),
      (.seconds(60), Int64(60000)),
      (.milliseconds(1), Int64(1))
    ] as [(Duration, Int64)]
  )
  func millisecondsConversion(duration: Duration, expected: Int64) {
    #expect(duration.milliseconds == expected)
  }

  @Test(
    "Microseconds conversion",
    arguments: [
      (Duration.seconds(1), Int64(1_000_000)),
      (.milliseconds(1), Int64(1000)),
      (.microseconds(1), Int64(1)),
    ] as [(Duration, Int64)]
  )
  func microsecondsConversion(duration: Duration, expected: Int64) {
    #expect(duration.microseconds == expected)
  }

  @Test(
    "Formatted minutes and seconds",
    arguments: [
      (Duration.seconds(65), "1:05"),
      (.seconds(600), "10:00"),
      (.seconds(0), "0:00"),
      (.seconds(59), "0:59"),
      (.seconds(3599), "59:59"),
    ] as [(Duration, String)]
  )
  func formattedMinutesAndSeconds(duration: Duration, expected: String) {
    #expect(duration.formatted == expected)
  }

  @Test("Formatted hours minutes seconds")
  func formattedHoursMinutesSeconds() {
    #expect(Duration.seconds(3661).formatted == "1:01:01")
  }

  @Test("Formatted zero duration")
  func formattedZeroDuration() {
    #expect(Duration.zero.formatted == "0:00")
  }

  @Test("Formatted negative duration")
  func formattedNegativeDuration() {
    #expect(Duration.seconds(-5).formatted == "-0:05")
  }

  @Test("Formatted sub-second duration")
  func formattedSubSecondDuration() {
    #expect(Duration.milliseconds(500).formatted == "0:00")
  }

  @Test(
    "Milliseconds round-trip",
    arguments: [Int64(0), 1, 500, 1000, 60000, 123_456] as [Int64]
  )
  func millisecondsRoundTrip(ms: Int64) {
    #expect(Duration.milliseconds(ms).milliseconds == ms)
  }

  @Test(
    "Microseconds round-trip",
    arguments: [Int64(0), 1, 1000, 1_000_000] as [Int64]
  )
  func microsecondsRoundTrip(us: Int64) {
    #expect(Duration.microseconds(us).microseconds == us)
  }

  @Test("Formatted large duration")
  func formattedLargeDuration() {
    #expect(Duration.seconds(86400).formatted == "24:00:00")
  }
}
