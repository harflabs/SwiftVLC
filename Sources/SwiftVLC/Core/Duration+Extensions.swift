extension Duration {
  /// Total duration in milliseconds.
  public var milliseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds * 1000 + attoseconds / 1_000_000_000_000_000
  }

  /// Total duration in microseconds.
  public var microseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
  }

  /// Formats the duration as a human-readable time string (e.g. "1:23:45" or "3:05").
  ///
  /// Negative durations are prefixed with "-" (e.g. "-0:05").
  public var formatted: String {
    let isNegative = milliseconds < 0
    let totalSeconds = Int(abs(milliseconds) / 1000)
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
