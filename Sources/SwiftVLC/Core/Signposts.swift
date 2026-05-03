import os

/// Process-wide `OSSignposter` for the SwiftVLC subsystem.
///
/// Hot paths use `signposter.beginInterval(...)` / `endInterval(...)` to
/// mark themselves on the `org.swiftvlc` subsystem under the
/// `pointsOfInterest` category. Instruments and `xctrace` pick these up
/// when the user starts a profiling session; in the absence of a
/// listener the calls are documented to be near-zero cost, so they are
/// safe to leave wired in release builds.
///
/// Naming: signpost names match the function they instrument
/// (`Broadcaster.broadcast`, `Player.handleEvent`, etc.) so traces map
/// 1:1 to source. The category is `.pointsOfInterest` so the hot paths
/// appear on the same Instruments swim lane regardless of which file
/// they live in.
enum Signposts {
  /// Subsystem identifier used by every signpost in SwiftVLC. Matches
  /// the bundle prefix so consumers can filter all SwiftVLC traces from
  /// their app's noise in Instruments.
  static let subsystem = "org.swiftvlc"

  /// Singleton `OSSignposter` shared across hot paths. `OSSignposter`
  /// is a struct that wraps a thread-safe handle, so a single shared
  /// instance is fine for the whole module.
  static let signposter = OSSignposter(
    subsystem: subsystem,
    category: OSLog.Category.pointsOfInterest
  )
}
