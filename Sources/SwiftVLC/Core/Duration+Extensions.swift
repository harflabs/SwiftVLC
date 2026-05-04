import Foundation

extension Duration {
  /// Total duration in milliseconds.
  ///
  /// Values outside `Int64`'s representable millisecond range saturate
  /// to `Int64.min` or `Int64.max` instead of trapping.
  public var milliseconds: Int64 {
    converted(toUnitsPerSecond: 1000).value
  }

  /// Total duration in microseconds.
  ///
  /// Values outside `Int64`'s representable microsecond range saturate
  /// to `Int64.min` or `Int64.max` instead of trapping.
  public var microseconds: Int64 {
    converted(toUnitsPerSecond: 1_000_000).value
  }

  /// Formats the duration as a human-readable time string (e.g. "1:23:45" or "3:05").
  ///
  /// Negative durations are prefixed with "-" (e.g. "-0:05").
  public var formatted: String {
    let ms = milliseconds
    let isNegative = ms < 0
    // Divide before `abs` so `Int64.min` (whose negation overflows) doesn't trap.
    let totalSeconds = Int(abs(ms / 1000))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    let prefix = isNegative ? "-" : ""
    if hours > 0 {
      return String(format: "%@%d:%02d:%02d", prefix, hours, minutes, seconds)
    }
    return String(format: "%@%d:%02d", prefix, minutes, seconds)
  }
}

extension Duration {
  func checkedMilliseconds(parameter: String) throws(VLCError) -> Int64 {
    let conversion = converted(toUnitsPerSecond: 1000)
    guard !conversion.overflow else {
      throw .invalidInput("\(parameter) is outside the supported millisecond range")
    }
    return conversion.value
  }

  func checkedNonnegativeMilliseconds(parameter: String) throws(VLCError) -> Int64 {
    let value = try checkedMilliseconds(parameter: parameter)
    guard value >= 0 else {
      throw .invalidInput("\(parameter) must be non-negative")
    }
    return value
  }

  func checkedNonnegativeInt32Milliseconds(parameter: String) throws(VLCError) -> Int32 {
    let value = try checkedNonnegativeMilliseconds(parameter: parameter)
    guard value <= Int64(Int32.max) else {
      throw .invalidInput("\(parameter) must fit in \(Int32.max) milliseconds")
    }
    return Int32(value)
  }

  func checkedMicroseconds(parameter: String) throws(VLCError) -> Int64 {
    let conversion = converted(toUnitsPerSecond: 1_000_000)
    guard !conversion.overflow else {
      throw .invalidInput("\(parameter) is outside the supported microsecond range")
    }
    return conversion.value
  }

  private func converted(toUnitsPerSecond unitsPerSecond: Int64) -> (value: Int64, overflow: Bool) {
    let (seconds, attoseconds) = components
    let attosecondsPerSecond: Int64 = 1_000_000_000_000_000_000
    let subsecondUnits = attoseconds / (attosecondsPerSecond / unitsPerSecond)

    let multiplied = seconds.multipliedReportingOverflow(by: unitsPerSecond)
    guard !multiplied.overflow else {
      return (seconds >= 0 ? .max : .min, true)
    }

    let added = multiplied.partialValue.addingReportingOverflow(subsecondUnits)
    guard !added.overflow else {
      return (subsecondUnits >= 0 ? .max : .min, true)
    }
    return (added.partialValue, false)
  }
}
