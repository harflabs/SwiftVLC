#if os(iOS) || os(macOS)
import AVKit
import CoreMedia
import Foundation
import Synchronization

/// The PiP state observer: the subscriptions that keep the control timebase
/// and the PiP transport in step with the player.
///
/// Split into its own file because almost every branch below is reachable
/// only while the player is actively playing, and CI cannot drive libVLC to
/// `.playing` at all (`TestCondition.canPlayMedia`). Keeping it here lets the
/// coverage gate stay enforced on the rest of ``PiPController`` while this
/// file is reported rather than enforced — see codecov.yml.
///
/// The decision logic that *can* be tested headlessly is deliberately pulled
/// out into ``PiPController/timebaseRetracking(isActive:rate:lastRate:hasTimebase:secondsSinceSkip:playerSeconds:timebaseSeconds:)``,
/// which is pure and fully covered.
extension PiPController {
  /// Drives the control timebase and PiP UI from player events.
  ///
  /// Subscribes to *both* lanes, one task each, because this observer needs
  /// what each lane guarantees and neither alone is sufficient:
  ///
  /// - Control events (`.mediaChanged`, `.lengthChanged`, `.seekableChanged`,
  ///   `.stateChanged`) are one-shot. Losing one leaves PiP permanently wrong
  ///   for the session — a dropped `.seekableChanged` pins seekable VOD to the
  ///   conservative media-changed reset, which is linear playback with no skip
  ///   controls. That lane is unbounded.
  /// - `.timeChanged` is the clock tick that drives capability convergence and
  ///   rate retracking. Steady playback can run without another state
  ///   transition, so those have to be reachable from a tick as well. Only the
  ///   newest tick means anything, so that lane stays coalesced.
  ///
  /// One merged stream cannot express both: a merge has a single buffer, so it
  /// either grows without bound under a stalled main actor or evicts control
  /// events. Previously this observer read the mixed `events` stream and took
  /// the second failure.
  ///
  /// Both tasks are `@MainActor`, so they serialize on this actor: the shared
  /// observation state is mutated between events, never during one. Cross-lane
  /// ordering is not guaranteed, which is why capability reconciliation is
  /// generation-guarded rather than order-dependent (see
  /// ``PlaybackStateObservationState/reconcile(with:invalidates:)``).
  ///
  /// The shape of each loop matches `Player.startEventConsumer`: pull via
  /// `for await` and bind `self` strongly *inside* the body, where the binding
  /// lasts a single iteration. The implicit suspension between events keeps
  /// only a weak reference in scope, so an observer never prevents the
  /// controller from deinitializing.
  func startStateObserver() {
    let controlEvents = player.controlEvents
    let timingEvents = player.timingEvents
    let initialActive = player.isPlaybackRequestedActive
    let initialNativeActive = player.isActive
    pipPlaybackActive = initialActive
    syncTimebase(playing: initialNativeActive, reason: .initialSynchronization)

    lastObservedNativeActive = initialNativeActive
    lastObservedRate = 1.0
    playbackStateObservation = PlaybackStateObservationState(
      duration: player.duration,
      isSeekable: player.isSeekable
    )

    stateObserverTask = Task { @MainActor [weak self] in
      for await event in controlEvents {
        guard let self else { return }
        handleStateObserverEvent(event)
      }
    }
    timingObserverTask = Task { @MainActor [weak self] in
      for await event in timingEvents {
        guard let self else { return }
        handleStateObserverEvent(event)
      }
    }
  }

  /// The body both lane tasks run. Identical work either way: what differs
  /// between the lanes is delivery guarantees, not handling.
  private func handleStateObserverEvent(_ event: PlayerEvent) {
    guard
      Self.shouldObservePlaybackStateEvent(
        event,
        suppressingRawCapabilityEvents: player.isSuppressingRawCapabilityEvents
      ) else { return }
    let active = player.isActive
    let rate = player.rate
    let playbackStateUpdate = playbackStateObservation.consume(
      event,
      capability: player.capabilitySnapshot.withLock { $0 }
    )
    applyObservedPlaybackStateUpdate(playbackStateUpdate)

    // State transition: sync the timebase rate.
    if active != lastObservedNativeActive {
      lastObservedNativeActive = active
      let didAcceptNativeState = handleObservedPlaybackActivity(active)

      if didAcceptNativeState {
        syncTimebase(playing: active)
      }

      if didAcceptNativeState, active {
        // Player is now actively playing — any prior PiP-issued
        // pause has been superseded by the user's intent.
        clearIssuedPauseFlag()
      }
    }

    let timebase = controlTimebase
    let time = player.currentTime
    let playerSeconds = Double(time.components.seconds)
      + Double(time.components.attoseconds) / 1e18
    let retracking = Self.timebaseRetracking(
      isActive: active,
      rate: rate,
      lastRate: lastObservedRate,
      hasTimebase: timebase != nil,
      isSkipPending: pendingSkipCount > 0,
      secondsSinceSkip: CFAbsoluteTimeGetCurrent() - lastSkipTimestamp,
      playerSeconds: playerSeconds,
      timebaseSeconds: timebase.map { CMTimebaseGetTime($0).seconds } ?? 0
    )

    if retracking.adoptsRate {
      lastObservedRate = rate
    }
    if let timebase {
      if let rate = retracking.setsRate {
        setTimebaseRate(
          Float64(rate),
          reason: .playbackRateTransition,
          mediaTimeSeconds: playerSeconds
        )
      }
      if let seconds = retracking.setsTime {
        let previousSeconds = CMTimebaseGetTime(timebase).seconds
        CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 1000))
        recordTimebaseCorrection(
          reason: .steadyStateDrift,
          previousTimebaseSeconds: previousSeconds,
          correctedTimebaseSeconds: seconds,
          mediaTimeSeconds: seconds
        )
      }
    }
  }

  /// What the control timebase should be told after an observed event.
  struct TimebaseRetracking: Equatable {
    /// Whether the observer should remember this rate as the last one seen.
    /// True on any change, including one seen while inactive — otherwise the
    /// comparison would fire again on the next event and never settle.
    var adoptsRate = false
    /// The rate to push onto the timebase, if any.
    var setsRate: Float?
    /// The time to push onto the timebase, if any.
    var setsTime: Double?
  }

  /// Decides the timebase updates for one observed event.
  ///
  /// Pure, and separated from the call site above for a reason the coverage
  /// config already names: every branch here is gated on the player being
  /// actively playing, and CI cannot drive libVLC to `.playing` at all (see
  /// `TestCondition.canPlayMedia`). Keeping the decision in a function that
  /// takes its inputs as parameters is what makes the rules testable
  /// headlessly instead of merely unreachable.
  ///
  /// The rules:
  /// - A rate change retracks the scrubber, which would otherwise advance at
  ///   1.0× while the player runs at 2.0× or 0.5×. `player.rate` has no
  ///   dedicated libVLC event, so this is picked up from whatever event
  ///   arrives next — clock ticks, during playback.
  /// - A large position divergence resyncs the timebase, which is how a seek
  ///   made from the app's own controls reaches the PiP scrubber.
  /// - Neither applies within a second of a PiP-issued skip, whose own
  ///   timebase write must not be overwritten while it settles.
  nonisolated static func timebaseRetracking(
    isActive: Bool,
    rate: Float,
    lastRate: Float,
    hasTimebase: Bool,
    isSkipPending: Bool,
    secondsSinceSkip: Double,
    playerSeconds: Double,
    timebaseSeconds: Double
  )
    -> TimebaseRetracking {
    var retracking = TimebaseRetracking()
    retracking.adoptsRate = rate != lastRate

    guard isActive, hasTimebase else { return retracking }

    if retracking.adoptsRate {
      retracking.setsRate = rate
    }
    if
      !isSkipPending,
      secondsSinceSkip > 1.0,
      abs(playerSeconds - timebaseSeconds) > 2.0 {
      retracking.setsTime = playerSeconds
    }
    return retracking
  }
}
#endif
