#if os(iOS) || os(macOS)

import CoreMedia

extension PiPController {
  /// How a PiP skip request finished.
  ///
  /// AVKit's contract is that the completion handler runs once the skip
  /// operation finishes or fails — never twice, and never not at all. Naming
  /// the outcomes makes "exactly once" checkable rather than assumed.
  enum SkipOutcome: Equatable {
    /// libVLC accepted the relative jump.
    case issued
    /// There was no session to seek in, or libVLC refused the request. The
    /// published timeline is left exactly as it was.
    case rejected
    /// AVKit handed over an interval that cannot be expressed in libVLC's
    /// millisecond unit — infinite, NaN, or out of range.
    case unrepresentableInterval
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
  static func performSkip(on player: Player, by interval: CMTime) -> SkipOutcome {
    guard let offsetMilliseconds = skipOffsetMilliseconds(interval) else {
      return .unrepresentableInterval
    }
    guard player.jump(by: .milliseconds(offsetMilliseconds)) else {
      return .rejected
    }
    return .issued
  }

  /// Whether this outcome means the timeline actually moved.
  ///
  /// A rejected skip must not be reflected anywhere: publishing the requested
  /// time as though it had landed puts the transport controls ahead of the
  /// media, and the next native clock sample then yanks them back.
  static func skipMovedTimeline(_ outcome: SkipOutcome) -> Bool {
    outcome == .issued
  }
}

#endif
