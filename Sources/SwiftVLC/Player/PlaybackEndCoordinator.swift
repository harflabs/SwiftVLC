import CLibVLC
import Synchronization

/// Decides, on libVLC's event thread, whether a `stopped` transition is a
/// natural end-of-media.
///
/// libVLC 4 collapses natural end and requested stop into the same `Stopped`
/// event. The patched engine reports an authoritative reason just before that
/// transition; the event callback synthesizes ``PlayerEvent/endReached`` only
/// for an explicit end-of-stream reason. A stop with no reason remains unknown.
///
/// The engine reason is recorded on its event thread; list-player suppression
/// is changed by `@MainActor` attachment code. Every access goes through one
/// `Mutex`.
final class PlaybackEndCoordinator: Sendable {
  private struct EndState {
    /// A `MediaListPlayer` drives this handle through list-player C
    /// calls that never pass through `Player.stop()` — every
    /// list-initiated advancement would synthesize a spurious end.
    var suppressSynthesis = false
    /// The engine's reason for the stop now in flight, when it supplied one.
    /// Cleared by each `stopped`, so it can never describe a later one.
    var stoppingReason: libvlc_stopping_reason_t?
  }

  private let state = Mutex(EndState())

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
  /// When it supplied none, the stop remains unattributed. Absence of a known
  /// cause is not evidence of EOF, so it must never be promoted to a confirmed
  /// natural end.
  func consumeStoppedShouldSynthesizeEnd() -> Bool {
    state.withLock { state in
      defer {
        state.stoppingReason = nil
      }

      if let reason = state.stoppingReason {
        // Still honour list-player suppression: an advance through a playlist
        // ends one media at eos without ending playback.
        return reason == libvlc_stopping_reason_eos && !state.suppressSynthesis
      }

      return false
    }
  }
}
