#if os(iOS) || os(macOS)

import CoreMedia

extension PiPController {
  /// How a PiP skip request finished.
  ///
  /// AVKit's contract is that the completion handler runs once the skip
  /// operation finishes or fails — never twice, and never not at all. Naming
  /// the outcomes makes "exactly once" checkable rather than assumed.
  enum SkipOutcome: Equatable, Sendable {
    /// libVLC accepted the relative jump and landing is still pending.
    case pending
    /// There was no session to seek in, or libVLC refused the request. The
    /// published timeline is left exactly as it was.
    case rejected
    /// The matching seek ended and its landed clock reached the observable timeline.
    case settled
    /// libVLC accepted the jump but emitted no landed timer point before the
    /// bounded settlement window elapsed.
    case timedOut
    /// A newer jump or media lifecycle transition replaced this request.
    case superseded
    /// AVKit handed over an interval that cannot be expressed in libVLC's
    /// millisecond unit — infinite, NaN, or out of range.
    case unrepresentableInterval
  }

  /// Initial dispatch classification plus one shared terminal result.
  struct SkipRequest: Sendable {
    private enum Resolution: Sendable {
      case resolved(SkipOutcome)
      case seek(SeekRequest)
    }

    let initialOutcome: SkipOutcome
    private let resolution: Resolution

    var outcome: SkipOutcome {
      get async {
        switch resolution {
        case .resolved(let outcome): outcome
        case .seek(let seekRequest):
          switch await seekRequest.outcome {
          case .pending: preconditionFailure("a terminal seek outcome cannot be pending")
          case .rejected: .rejected
          case .settled: .settled
          case .inaccurate: .rejected
          case .timedOut: .timedOut
          case .superseded: .superseded
          }
        }
      }
    }

    init(resolved outcome: SkipOutcome) {
      precondition(outcome != .pending)
      initialOutcome = switch outcome {
      case .rejected, .unrepresentableInterval: outcome
      case .settled, .timedOut, .superseded: .pending
      case .pending: preconditionFailure("pending is not terminal")
      }
      resolution = .resolved(outcome)
    }

    init(seekRequest: SeekRequest) {
      initialOutcome = seekRequest.initialOutcome == .rejected ? .rejected : .pending
      resolution = .seek(seekRequest)
    }
  }

  /// Routes an AVKit skip through the player's relative jump.
  ///
  /// Every PiP backend funnels through here. Previously each of the three
  /// converted the interval into an absolute target itself and issued a strict
  /// seek, which has two problems:
  ///
  /// - The strict path needs a known duration and validates against it, so on
  ///   live and timeshift media — exactly where a DVR skip is most useful —
  ///   there is no target to derive. ``Player/jump(by:)`` jumps relative to the
  ///   input's own clock and works there.
  /// - Converting to an absolute target discards the interval AVKit asked for.
  ///   Rounding through `currentTime`, which is itself an estimate between
  ///   native clock samples, makes the skip land somewhere other than exactly
  ///   the requested distance away.
  ///
  /// The interval is therefore preserved and handed to libVLC as a relative
  /// offset.
  @MainActor
  static func performSkip(on player: Player, by interval: CMTime) -> SkipRequest {
    guard let offsetMilliseconds = skipOffsetMilliseconds(interval) else {
      return SkipRequest(resolved: .unrepresentableInterval)
    }
    return SkipRequest(
      seekRequest: player.requestJump(by: .milliseconds(offsetMilliseconds))
    )
  }

  /// Whether this outcome means the timeline actually moved.
  ///
  /// A rejected skip must not be reflected anywhere: publishing the requested
  /// time as though it had landed puts the transport controls ahead of the
  /// media, and the next native clock sample then yanks them back.
  static func skipMovedTimeline(_ outcome: SkipOutcome) -> Bool {
    outcome == .settled
  }
}

#endif
