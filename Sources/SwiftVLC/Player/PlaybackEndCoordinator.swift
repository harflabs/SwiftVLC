import CLibVLC
import Synchronization

/// Decides, on libVLC's event thread, whether a `stopped` transition is a
/// natural end-of-media.
///
/// libVLC 4 collapses natural end and requested stop into the same
/// `Stopped` event. Every cause that should suppress synthesis —
/// a library-issued `stop()`, a decoding error, an attached
/// ``MediaListPlayer`` driving the handle — is recorded here, and the
/// event callback synthesizes ``PlayerEvent/endReached`` only when a
/// `stopped` arrives with none of them pending.
///
/// Causes are recorded by `@MainActor` callers (`Player`'s library
/// stop, `MediaListPlayer`'s suppression) and by the event callback
/// itself (errors); the callback consumes them on `stopped`. Every
/// access goes through one `Mutex`, and main-actor causes are recorded
/// *before* the native call that will eventually produce the `Stopped`.
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
    /// The engine's reason for the stop now in flight, when it supplied one.
    /// Cleared by each `stopped`, so it can never describe a later one.
    var stoppingReason: libvlc_stopping_reason_t?
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
      // A reason recorded on the outgoing handle describes a stop that will
      // never arrive here. Left behind, it would classify the *successor's*
      // first stop — `MediaPlayerMediaStopping` can precede a replacement that
      // lands before the matching `stopped` is observed.
      $0.stoppingReason = nil
    }
  }

  /// Flips list-player suppression. Set while a `MediaListPlayer` is
  /// attached; cleared on detach.
  func setSuppressed(_ suppressed: Bool) {
    state.withLock { $0.suppressSynthesis = suppressed }
  }

  /// Records the engine's own reason for the stop that is about to arrive.
  ///
  /// libVLC reports this on `MediaPlayerMediaStopping`, which precedes the
  /// `stopped` transition. It is authoritative: the player core knows whether
  /// the input reached end of stream, was stopped by request, or failed.
  func noteStoppingReason(_ reason: libvlc_stopping_reason_t) {
    state.withLock { $0.stoppingReason = reason }
  }

  /// Consumes a `stopped` transition on the event thread: returns `true`
  /// when it should synthesize ``PlayerEvent/endReached``, and clears the
  /// one-shot causes either way (each `stopped` accounts for whatever
  /// preceded it).
  ///
  /// When the engine supplied a reason, it decides: only `eos` is a natural
  /// end, and `user` and `error` are not.
  ///
  /// When it supplied none, the inference below applies unchanged — an engine
  /// that does not report a reason must keep working, not lose end-of-media
  /// entirely. That fallback is the weaker answer, and knowing why matters: it
  /// concludes "natural end" from the *absence* of a known cause, so anything
  /// it has not been told about reads as end of media. Supplying a reason is
  /// what removes the guesswork, not the fallback itself.
  func consumeStoppedShouldSynthesizeEnd() -> Bool {
    state.withLock { state in
      defer {
        state.libraryStopPending = false
        state.sawErrorSinceLastPlay = false
        state.stoppingReason = nil
      }

      if let reason = state.stoppingReason {
        // Still honour list-player suppression: an advance through a playlist
        // ends one media at eos without ending playback.
        return reason == libvlc_stopping_reason_eos && !state.suppressSynthesis
      }

      return !state.libraryStopPending
        && !state.sawErrorSinceLastPlay
        && !state.suppressSynthesis
    }
  }
}
