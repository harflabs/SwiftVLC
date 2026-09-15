import Synchronization

/// The lifecycle state of an authoritative seek request.
///
/// A native seek is asynchronous. ``pending`` means SwiftVLC accepted the
/// command into its media-player-local seek lane but has not yet published
/// authoritative native landing evidence. On libVLC 4, a newer command may be
/// waiting behind one active untagged native seek rather than dispatched yet.
/// libVLC 4 retains an integer result for ABI compatibility, but its current
/// seek entry points return zero after dispatch without reporting whether the
/// demuxer can honor the request. On native extension v12, video selected at dispatch resolves from successful output
/// submission after seek end. Older engines use a watched timer point; paused audio-only input instead uses a
/// direct post-end clock read because it may not produce another point until
/// playback resumes. Every request eventually reaches one of the other,
/// terminal cases.
public enum SeekOutcome: Hashable, Sendable {
  /// The request was accepted and is waiting for native dispatch or landing evidence.
  case pending
  /// The request was invalid for the current playback session or its native
  /// dispatch reported a failure. An immediately rejected command does not
  /// change the observable timeline. A command rejected after waiting in the
  /// lane also publishes no target because timeline authority is adopted only
  /// after native dispatch accepts it.
  case rejected
  /// The dispatched seek ended and its observed landing reached the mirror.
  /// With native extension v12, video selected at dispatch requires a successful output
  /// submission. Precise absolute video seeks with a known target also require a landing within one
  /// reported frame duration after the target (1ms timestamp rounding allowed).
  /// Older engines retain their clock-only compatibility behavior.
  case settled
  /// Video was submitted, but its timestamp did not satisfy the precise
  /// target bound. The mirror reports the observed landing, not the target.
  case inaccurate
  /// Native dispatch or authoritative landing did not arrive within its
  /// bounded phase window. Dispatch refreshes the window after any queued wait.
  /// This ends observation, not the seek intent: the latest queued command
  /// may still dispatch, and a late landing still updates observed playback.
  /// A newer seek or a media/playback replacement supersedes that intent.
  case timedOut
  /// A newer seek, media replacement, terminal playback state, or teardown
  /// made this request no longer authoritative.
  case superseded
}

/// An accepted-or-rejected seek together with its authoritative result.
///
/// Inspect ``initialOutcome`` synchronously to learn whether SwiftVLC accepted
/// the command into its seek lane. It does not prove native dispatch has begun
/// or that the input honored the command. If it is
/// ``SeekOutcome/pending``, await ``outcome`` for the eventual landing, timeout,
/// or supersession. Waiting is cancellation-safe: cancelling one waiter does
/// not cancel or reclassify the underlying seek.
public struct SeekRequest: Sendable {
  private enum Resolution: Sendable {
    case resolved(SeekOutcome)
    case pending(SeekOutcomeResolver)
  }

  /// The result known when SwiftVLC accepts or rejects the command.
  ///
  /// This is either ``SeekOutcome/pending`` or ``SeekOutcome/rejected``.
  public let initialOutcome: SeekOutcome

  private let resolution: Resolution

  /// The authoritative terminal result.
  ///
  /// Rejected requests return immediately. Accepted requests suspend until the
  /// sole serialized native episode publishes a landing, native dispatch
  /// later rejects a queued command, the request times out, or newer work
  /// supersedes it.
  public var outcome: SeekOutcome {
    get async {
      switch resolution {
      case .resolved(let outcome): outcome
      case .pending(let resolver): await resolver.outcome()
      }
    }
  }

  init(resolved outcome: SeekOutcome) {
    precondition(outcome != .pending)
    initialOutcome = outcome == .rejected ? .rejected : .pending
    resolution = .resolved(outcome)
  }

  init(resolver: SeekOutcomeResolver) {
    initialOutcome = .pending
    resolution = .pending(resolver)
  }
}

/// Single-assignment promise shared by Player's main-actor state machine and
/// every task awaiting a copied ``SeekRequest``.
///
/// Multiple waiters register under one lock and are resumed with the same
/// value. Cancelling a waiter cannot cancel the seek, and accidental duplicate
/// settlement is harmless.
final class SeekOutcomeResolver: Sendable {
  private struct State: Sendable {
    var outcome: SeekOutcome?
    var waiters: [CheckedContinuation<SeekOutcome, Never>] = []
  }

  private let state = Mutex(State())

  func outcome() async -> SeekOutcome {
    await withCheckedContinuation { continuation in
      let immediate = state.withLock { state -> SeekOutcome? in
        guard let outcome = state.outcome else {
          state.waiters.append(continuation)
          return nil
        }
        return outcome
      }
      if let immediate {
        continuation.resume(returning: immediate)
      }
    }
  }

  @discardableResult
  func resolve(_ outcome: SeekOutcome) -> Bool {
    precondition(outcome != .pending)
    let waiters = state.withLock { state -> [CheckedContinuation<SeekOutcome, Never>]? in
      guard state.outcome == nil else { return nil }
      state.outcome = outcome
      defer { state.waiters.removeAll(keepingCapacity: false) }
      return state.waiters
    }
    guard let waiters else { return false }
    for waiter in waiters {
      waiter.resume(returning: outcome)
    }
    return true
  }

  #if DEBUG
  var resolvedOutcome: SeekOutcome? {
    state.withLock { $0.outcome }
  }
  #endif
}
