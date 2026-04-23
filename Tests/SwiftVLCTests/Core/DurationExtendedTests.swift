@testable import SwiftVLC
import Testing

extension Logic {
  struct DurationExtendedTests {
    @Test
    func `Negative duration formatting prefixed with minus`() {
      #expect(Duration.seconds(-65).formatted == "-1:05")
      #expect(Duration.seconds(-1).formatted == "-0:01")
      #expect(Duration.seconds(-3661).formatted == "-1:01:01")
    }

    @Test
    func `Zero duration milliseconds and microseconds`() {
      #expect(Duration.zero.milliseconds == 0)
      #expect(Duration.zero.microseconds == 0)
    }

    @Test
    func `Very large durations in hours`() {
      // 100 hours
      #expect(Duration.seconds(360_000).formatted == "100:00:00")
      // 999 hours
      #expect(Duration.seconds(3_596_400).formatted == "999:00:00")
    }

    @Test
    func `Formatted for exactly 1 hour`() {
      #expect(Duration.seconds(3600).formatted == "1:00:00")
    }

    @Test
    func `Formatted for greater than 1 hour shows H MM SS format`() {
      #expect(Duration.seconds(3601).formatted == "1:00:01")
      #expect(Duration.seconds(7200).formatted == "2:00:00")
      #expect(Duration.seconds(7261).formatted == "2:01:01")
      #expect(Duration.seconds(36000).formatted == "10:00:00")
    }

    @Test
    func `Formatted for less than 1 hour shows M SS format`() {
      #expect(Duration.seconds(59).formatted == "0:59")
      #expect(Duration.seconds(60).formatted == "1:00")
      #expect(Duration.seconds(600).formatted == "10:00")
      #expect(Duration.seconds(3599).formatted == "59:59")
    }

    @Test
    func `Millisecond and microsecond conversion consistency`() {
      let duration = Duration.milliseconds(12345)
      #expect(duration.milliseconds == 12345)
      #expect(duration.microseconds == 12_345_000)
      #expect(duration.microseconds == duration.milliseconds * 1000)
    }

    @Test
    func `Negative duration milliseconds and microseconds`() {
      let neg = Duration.seconds(-3)
      #expect(neg.milliseconds == -3000)
      #expect(neg.microseconds == -3_000_000)

      let negMs = Duration.milliseconds(-500)
      #expect(negMs.milliseconds == -500)
      #expect(negMs.microseconds == -500_000)
    }

    @Test
    func `Sub-second duration formatting`() {
      #expect(Duration.milliseconds(1).formatted == "0:00")
      #expect(Duration.milliseconds(999).formatted == "0:00")
      #expect(Duration.milliseconds(500).formatted == "0:00")
      #expect(Duration.milliseconds(1500).formatted == "0:01")
    }

    @Test
    func `Formatted for exactly zero shows 0 colon 00`() {
      #expect(Duration.zero.formatted == "0:00")
      #expect(Duration.seconds(0).formatted == "0:00")
      #expect(Duration.milliseconds(0).formatted == "0:00")
    }
  }
}
