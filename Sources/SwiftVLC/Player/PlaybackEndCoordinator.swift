import Synchronization

/// Decides, on libVLC's event thread, whether a `stopped` transition is a
/// natural end-of-media.
///
/// libVLC 4 collapses natural end and requested stop into the same
/// `Stopped` event. The player records every cause it knows about —
/// a library-issued `stop()`, a decoding error, an attached
/// ``MediaListPlayer`` driving the handle — and the event callback
/// synthesizes ``PlayerEvent/endReached`` only when a `stopped` arrives
/// with none of them pending.
///
/// Shared between the `@MainActor` player (writer) and the C-callback
/// context (consumer); every access goes through one `Mutex`, and the
/// event thread's ordering is authoritative: causes are recorded *before*
/// the native call that will eventually produce the `Stopped`.
final class PlaybackEndCoordinator: Sendable {
  private struct EndState {
    /// A library-issued stop is in flight; the next `stopped` is not a
    /// natural end. Consumed (cleared) by that `stopped`.
    var libraryStopPending = false
    /// A decode/input error was reported for the current session; the
    /// `stopped` that follows it must not read as a natural end.
    /// Consumed by that `stopped`.
    var sawErrorSinceLastPlay = false
    /// A `MediaListPlayer` drives this handle through list-player C
    /// calls that never pass through `Player.stop()` — every
    /// list-initiated advancement would synthesize a spurious end.
    var suppressSynthesis = false
  }

  private let state = Mutex(EndState())

  /// Records a library-issued stop. Call *before*
  /// `libvlc_media_player_stop_async`, and skip the call entirely when
  /// the native player is already terminal — a stop on a stopped player
  /// emits no new `Stopped`, so the flag would go stale and silently
  /// swallow the next genuine natural end.
  func markLibraryStop() {
    state.withLock { $0.libraryStopPending = true }
  }

  /// Records an error event for the current playback session.
  func markError() {
    state.withLock { $0.sawErrorSinceLastPlay = true }
  }

  /// Clears every pending cause. Only for the native-handle replacement
  /// path, where the old handle's `Stopped` can never be observed (the
  /// bridge is reattached first): a flag left set there would suppress
  /// the *next* genuine natural end. On the plain `load()` path the
  /// pending `Stopped` still arrives and consumes its own flags — do
  /// not clear there, or an in-flight stop's `Stopped` lands after the
  /// clear and reads as a phantom natural end of media that never
  /// played.
  func clearForHandleReplacement() {
    state.withLock {
      $0.libraryStopPending = false
      $0.sawErrorSinceLastPlay = false
    }
  }

  /// Flips list-player suppression. Set while a `MediaListPlayer` is
  /// attached; cleared on detach.
  func setSuppressed(_ suppressed: Bool) {
    state.withLock { $0.suppressSynthesis = suppressed }
  }

  /// Consumes a `stopped` transition on the event thread: returns `true`
  /// when it should synthesize ``PlayerEvent/endReached``, and clears the
  /// one-shot causes either way (each `stopped` accounts for whatever
  /// preceded it).
  func consumeStoppedShouldSynthesizeEnd() -> Bool {
    state.withLock { state in
      let synthesize = !state.libraryStopPending
        && !state.sawErrorSinceLastPlay
        && !state.suppressSynthesis
      state.libraryStopPending = false
      state.sawErrorSinceLastPlay = false
      return synthesize
    }
  }
}
