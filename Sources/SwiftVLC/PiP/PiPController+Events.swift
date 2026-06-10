#if os(iOS) || os(macOS)
import Foundation

/// The reason a Picture-in-Picture window stopped (or is stopping).
///
/// Reason fidelity depends on which PiP backend is driving the window —
/// see ``PiPController/pipEvents`` for the per-backend guarantees and
/// the resolution rules.
public enum PiPStopReason: Sendable, Equatable {
  /// The user dismissed the PiP window with its close (X) affordance.
  ///
  /// Only reported on the sample-buffer path, where SwiftVLC owns the
  /// `AVPictureInPictureController` delegate: a stop with no restore
  /// request, no start failure, no programmatic ``PiPController/stop()``,
  /// and no end-of-media is attributed to the close button.
  case userClosed

  /// The user tapped the PiP window's restore ("return to app")
  /// affordance. Fires alongside ``PiPController/onRestoreUserInterface``.
  case restoreRequested

  /// The stop follows a failed PiP start (see
  /// ``PiPEvent/failedToStart(_:)``).
  case failure

  /// Playback reached the end of the media while PiP was up.
  case mediaEnded

  /// No discriminating signal was available. Reported for programmatic
  /// ``PiPController/stop()`` calls, for every stop on the native
  /// drawable path (including PiP torn down by a native-handle
  /// replacement such as a player swap or renderer recast), and for any
  /// stop AVKit performs without a delegate signal SwiftVLC can read.
  case unknown
}

/// A Picture-in-Picture lifecycle transition, delivered on
/// ``PiPController/pipEvents``.
public enum PiPEvent: Sendable {
  /// AVKit is about to present the PiP window.
  case willStart

  /// The PiP window is up.
  case didStart

  /// The PiP window is about to close. `reason` is the best-known
  /// reason *at this instant*; AVKit does not document whether the
  /// restore callback precedes this event, so prefer the reason
  /// attached to the subsequent ``didStop(reason:)``, which is
  /// authoritative.
  case willStop(reason: PiPStopReason)

  /// The PiP window closed.
  case didStop(reason: PiPStopReason)

  /// AVKit failed to start PiP. Carries the underlying AVKit error.
  case failedToStart(any Error)
}

// MARK: - Lifecycle event stream

extension PiPController {
  /// A stream of Picture-in-Picture lifecycle events.
  ///
  /// Each access returns an independent, unbounded stream — lifecycle
  /// events are one-shot and low-rate, so no event is ever dropped for
  /// a live subscriber. Streams finish when the controller deinits.
  ///
  /// ## Backend fidelity
  ///
  /// On the **sample-buffer path** (a directly constructed
  /// `PiPController`), SwiftVLC owns the `AVPictureInPictureController`
  /// delegate and every case is delivered, including
  /// ``PiPEvent/willStart``, ``PiPEvent/willStop(reason:)`` and
  /// ``PiPEvent/failedToStart(_:)`` with the underlying AVKit error.
  ///
  /// On the **native drawable path** (``PiPVideoView``), libVLC owns
  /// the AVKit controller and its delegate; the only signal SwiftVLC
  /// observes is the active flag flipping. There the stream degrades
  /// to synthesized ``PiPEvent/didStart`` / ``PiPEvent/didStop(reason:)``
  /// events whose reason is always ``PiPStopReason/unknown``;
  /// will/failed events are unavailable. A native-handle replacement
  /// while PiP is active (player swap, renderer recast) tears PiP down
  /// the same way and is likewise reported as `didStop(reason: .unknown)`.
  ///
  /// ## Stop-reason resolution
  ///
  /// The reason attached to ``PiPEvent/didStop(reason:)`` is resolved
  /// in this order:
  ///
  /// 1. The **first discriminating signal** observed for the in-flight
  ///    stop wins and is never overwritten: the restore callback
  ///    records ``PiPStopReason/restoreRequested``, a start failure
  ///    records ``PiPStopReason/failure``, and a programmatic
  ///    ``stop()`` records ``PiPStopReason/unknown``. In practice these
  ///    signals are mutually exclusive, which yields the effective
  ///    precedence `restoreRequested` > `failure` over the fallbacks
  ///    below.
  /// 2. Otherwise, if the player reported a natural end of media
  ///    (``Player/didReachEnd``), the stop is ``PiPStopReason/mediaEnded``.
  /// 3. Otherwise ``PiPStopReason/userClosed`` — on the sample-buffer
  ///    path the close (X) button is the only remaining cause.
  ///
  /// ``PiPEvent/willStop(reason:)`` carries the best-known reason at
  /// emission time. AVKit guarantees the restore callback completes
  /// before the stop finishes (so `didStop` always sees it) but does
  /// not document its order relative to `willStop`; treat `didStop`'s
  /// reason as authoritative.
  public var pipEvents: AsyncStream<PiPEvent> {
    pipEventBroadcaster.subscribe(policy: .unbounded)
  }

  /// Records the best-known reason for the in-flight stop. First
  /// discriminating signal wins; later signals never overwrite it (see
  /// ``pipEvents`` for the resulting precedence).
  func notePendingStopReason(_ reason: PiPStopReason) {
    guard pendingStopReason == nil else { return }
    pendingStopReason = reason
  }

  /// Resolves the stop reason for the in-flight stop without clearing
  /// it: pending discriminating signal, else natural end of media,
  /// else the user's close affordance.
  func resolveStopReason() -> PiPStopReason {
    if let pendingStopReason {
      return pendingStopReason
    }
    if player.didReachEnd {
      return .mediaEnded
    }
    return .userClosed
  }
}

#endif
