@testable import SwiftVLC

/// VLC instances tuned for deterministic integration tests.
///
/// Two problems rule out using `VLCInstance.shared` directly from tests:
///
/// 1. **No `NSApplication` in `swift test`.** libVLC fails to create a
///    video-output window and the decoder deadlocks before the player
///    ever reaches `.playing`. Passing `--no-video` skips video output
///    entirely and avoids the deadlock.
/// 2. **Cross-test libVLC state.** The debug libVLC carries per-instance
///    decoder / aout state that occasionally survives a `Player`
///    teardown and trips `assert(stream->timing.pause_date ==
///    VLC_TICK_INVALID)` when the next test rapidly creates another
///    player on the same instance. Giving each playback-driving test
///    its own instance isolates that state.
///
/// The cost of a fresh instance (~50 ms) is negligible. Tests that only
/// create and destroy objects without reaching `.playing` can still use
/// ``shared`` to avoid paying that cost repeatedly.
enum TestInstance {
  private static let audioOnlyArguments = VLCInstance.defaultArguments + [
    // `--no-video` avoids the `NSApplication` requirement for the
    // video-output window.
    //
    // `--no-audio` skips libVLC's audio-output subsystem entirely. The
    // debug build ships with `assert(stream->timing.pause_date ==
    // VLC_TICK_INVALID)` inside the decoder's stream-play path, which
    // trips intermittently when tests pause/resume a player quickly
    // after reaching `.playing`. Disabling audio output means the
    // stream-play path is never entered; the wrapper's state-machine
    // events, lifecycle, and C API calls are still fully exercised.
    "--no-video",
    "--no-audio",
    "--quiet"
  ]

  /// Creates an independent VLC instance with audio and video outputs
  /// disabled. Call this in the body of any test that drives playback
  /// to `.playing` — isolation keeps libVLC's decoder / aout state from
  /// bleeding into the next test.
  ///
  /// `try!` is appropriate: if libVLC can't initialize at all, the whole
  /// test target is unrunnable, so failing fast is the right behavior.
  static func makeAudioOnly() -> VLCInstance {
    try! VLCInstance(arguments: audioOnlyArguments)
  }

  /// A single shared instance for tests that only exercise lightweight
  /// lifecycle behavior (create + destroy without reaching `.playing`).
  /// Skips the ~50 ms instance-creation cost for tests that don't need
  /// per-test isolation.
  static let shared: VLCInstance = makeAudioOnly()
}
