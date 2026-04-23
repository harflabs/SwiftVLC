@testable import SwiftVLC

/// VLC instances tuned for deterministic integration tests.
///
/// Two problems rule out using `VLCInstance.shared` directly from tests:
///
/// 1. **No `NSApplication` / window server / audio device in
///    `swift test`.** libVLC's real vout and aout modules fail to
///    initialize and the decoder stalls before reaching `.playing`.
///    The `dummy` output modules (wired via ``makePlayback()`` and
///    ``shared``) provide no-op sinks so the decoder can progress.
/// 2. **Cross-test libVLC state.** The debug libVLC carries per-instance
///    decoder / aout state that occasionally survives a `Player`
///    teardown and trips `assert(stream->timing.pause_date ==
///    VLC_TICK_INVALID)` when the next test rapidly creates another
///    player on the same instance. Giving each playback-driving test
///    its own instance isolates that state.
///
/// The cost of a fresh instance (~50 ms) is negligible. Tests that only
/// create and destroy objects without reaching `.playing` can use
/// ``lifecycleShared`` (no outputs, skips the stream-play path);
/// playback-driving tests that don't need per-test isolation can use
/// ``shared`` (dummy outputs).
enum TestInstance {
  /// libVLC arguments for tests that only need lifecycle coverage —
  /// instance / player / event-bridge creation and teardown, without
  /// actually driving the state machine into `.playing`. Disabling both
  /// subsystems skips the stream-play path that, under rapid
  /// pause/resume on the debug libvlc, trips
  /// `assert(stream->timing.pause_date == VLC_TICK_INVALID)` in
  /// `src/audio_output/dec.c`.
  private static let lifecycleArguments = VLCInstance.defaultArguments + [
    "--no-video",
    "--no-audio",
    "--quiet"
  ]

  /// libVLC arguments for tests that need to reach `.playing`. Forces
  /// the `dummy` audio and video output modules so the decoder can
  /// progress the state machine in a headless environment, where no
  /// window server or audio device is available.
  ///
  /// Do **not** use this for tests that attach vmem callbacks (PiP) —
  /// once vmem takes over the vout, the dummy aout still runs and the
  /// combination with a real decoder trips an upstream ffmpeg
  /// `bytestream.h:141 buf_size >= 0` assertion on our fixtures. PiP
  /// tests should use ``makeAudioOnly()`` / ``lifecycleShared``
  /// instead.
  private static let playbackArguments = VLCInstance.defaultArguments + [
    "--vout=dummy",
    "--aout=dummy",
    "--quiet"
  ]

  /// Creates an independent VLC instance with audio and video outputs
  /// disabled. Call this for tests that only exercise Swift-side
  /// lifecycle and don't depend on reaching `.playing` — isolation
  /// keeps libVLC's decoder / aout state from bleeding into the next
  /// test.
  ///
  /// The name is historical; it predates the current setup where both
  /// audio and video outputs are disabled (see ``lifecycleArguments``).
  /// The call sites are spread across ~30 test files, so renaming is
  /// deferred to avoid churn; new call sites are free to prefer
  /// ``makePlayback()`` when they need to reach `.playing`.
  ///
  /// `try!` is appropriate: if libVLC can't initialize at all, the whole
  /// test target is unrunnable, so failing fast is the right behavior.
  static func makeAudioOnly() -> VLCInstance {
    try! VLCInstance(arguments: lifecycleArguments)
  }

  /// Creates an independent VLC instance wired to libVLC's dummy audio
  /// and video output modules. Use in tests that drive playback to
  /// `.playing` in a headless environment — the dummy outputs let the
  /// decoder progress the state machine without needing real hardware.
  static func makePlayback() -> VLCInstance {
    try! VLCInstance(arguments: playbackArguments)
  }

  /// A single shared instance with audio and video outputs disabled.
  /// Default for tests that don't care about per-test isolation and
  /// don't need to reach `.playing`. Skips the ~50 ms instance-creation
  /// cost for lightweight lifecycle tests.
  ///
  /// Dummy-output wiring is deliberately **not** the default: GitHub
  /// Actions' `macos-latest` runners are paravirtualized and crash
  /// inside `IOServiceMatching("AppleM2ScalerParavirtDriver")` when
  /// libVLC probes for hardware video acceleration — even if the test
  /// never calls `play()`. Tests that need to reach `.playing` should
  /// opt into ``makePlayback()`` explicitly and remain gated by
  /// ``TestCondition/canPlayMedia``.
  static let shared: VLCInstance = makeAudioOnly()
}
