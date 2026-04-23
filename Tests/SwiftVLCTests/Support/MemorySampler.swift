import Darwin
import Foundation

/// Samples the current process's resident memory via
/// `mach_task_basic_info`. Returns the RSS (physical footprint) in bytes.
///
/// Intended for pressure tests that care about gross allocation growth
/// across a churn loop, not precise accounting. Swift object leaks
/// surface here just as reliably as C-side CVPixelBuffer / libVLC
/// allocator leaks that weak-reference probes can't see.
///
/// A single call is a few microseconds; safe to invoke inside a loop,
/// though the interesting measurements are the delta between two points.
enum MemorySampler {
  /// Resident set size of the current process, in bytes. Returns `0` on
  /// failure — callers should treat a zero reading as "don't trust this
  /// sample" and either retry or skip the assertion. Failure in practice
  /// only happens if the mach call is denied, which doesn't occur under
  /// the test harness.
  static func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
      }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
  }

  /// Signed RSS delta in megabytes between two samples. Returns a
  /// negative number when memory dropped (allocator releases + OS
  /// reclaim) and a positive one when it grew.
  ///
  /// Use this instead of `&-` on raw byte counts: the malloc subsystem
  /// can return memory back to the OS between two `residentBytes()`
  /// calls, and an unsigned subtraction wraps to a 16-PB spike that
  /// no real leak would produce.
  static func deltaMB(from earlier: UInt64, to later: UInt64) -> Double {
    let diff = Int64(bitPattern: later) - Int64(bitPattern: earlier)
    return Double(diff) / 1_048_576
  }
}
