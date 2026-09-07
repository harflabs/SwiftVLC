@testable import SwiftVLC
import CustomDump
import Foundation
import Synchronization
import Testing

private struct SeekLandingMirror: Equatable {
  let currentTime: Duration
  let position: Double
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekLandingReconciliationTests {
    /// The strict absolute-time surface shares the same optimistic-publication
    /// rule as fractional seeking and must retain native landing evidence too.
    @Test
    func `A paused absolute seek reconciles its optimistic target with the native landing`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        currentTime: .seconds(10),
        duration: .seconds(100),
        position: 0.1,
        isSeekable: true
      )
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeSeekBaselineOverrideForTesting = { (10000, 0.1) }
      var nativePoint = (timeMilliseconds: Int64(10000), position: 0.1)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(42), fast: true)
      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(42), position: 0.42)
      )

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement != nil)
      nativePoint = (39000, 0.39)
      player._pollPendingSeekForTesting()
      #expect(player.currentTime == .seconds(42))
      #expect(player.pendingSeekSettlement != nil)
      player._pollPendingSeekForTesting()

      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(39), position: 0.39)
      )
      #expect(player.pendingSeekSettlement == nil)
    }

    /// libVLC 4's seek functions return zero after dispatch regardless of
    /// whether the demuxer will land at the requested point. A fast seek can
    /// therefore publish an optimistic target that differs from the actual
    /// keyframe. Paused playback may not emit the ordinary time event that used
    /// to correct that shadow, but the time-watch seek end still provides an
    /// authoritative clock read.
    @Test
    func `A paused position seek reconciles its optimistic target with the native landing`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100),
        position: 0.1
      )
      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeSeekBaselineOverrideForTesting = { (10000, 0.1) }
      var nativePoint = (timeMilliseconds: Int64(10000), position: 0.1)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      #expect(player.seek(toPosition: PlaybackPosition(0.5), fast: true))
      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(50), position: 0.5)
      )

      // The override bypasses libVLC, whose real set-position call emits the
      // seek-start callback synchronously while holding the player lock.
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement != nil)
      nativePoint = (41000, 0.41)
      player._pollPendingSeekForTesting()
      #expect(player.currentTime == .seconds(50))
      #expect(player.pendingSeekSettlement != nil)
      player._pollPendingSeekForTesting()

      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(41), position: 0.41)
      )
      #expect(player.pendingSeekSettlement == nil)
    }

    @Test
    func `Known duration rejects stable changed position beside baseline time`() async {
      let player = makePausedSeekPlayer()
      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      #expect(player.seek(toPosition: PlaybackPosition(0.8), fast: true))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement != nil)

      nativePoint = (2000, 0.6)
      player._pollPendingSeekForTesting()
      player._pollPendingSeekForTesting()

      // The separate position getter changed twice, but the authoritative
      // time getter still names the baseline. Deriving a position from that
      // time would snap the optimistic target back to the baseline.
      #expect(player.pendingSeekSettlement != nil)
      #expect(player.currentTime == .seconds(48))
      #expect(abs(player.position - 0.8) < 0.000_001)

      nativePoint = (36000, 0.6)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)
      player._pollPendingSeekForTesting()

      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(36))
      #expect(abs(player.position - 0.6) < 0.000_001)
    }

    @Test
    func `Known duration rejects a stable but contradictory paused clock pair`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30))
      let resolver = try #require(player.pendingSeekSettlement?.resolver)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      nativePoint = (29000, 0.9)
      player._pollPendingSeekForTesting()
      player._pollPendingSeekForTesting()

      #expect(player.pendingSeekSettlement != nil)
      #expect(player.currentTime == .seconds(30))
      #expect(abs(player.position - 0.5) < 0.000_001)

      player._expirePendingSeekForTesting()
      #expect(resolver.resolvedOutcome == .timedOut)
    }

    @Test
    func `Known duration accepts a stable coherent paused clock pair`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      nativePoint = (29000, 29.0 / 60.0)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)
      player._pollPendingSeekForTesting()

      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(29))
      #expect(abs(player.position - (29.0 / 60.0)) < 0.000_001)
    }

    @Test
    func `No time watched point settles position seek from valid fraction`() async {
      let player = makePausedSeekPlayer()
      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }

      #expect(player.seek(toPosition: PlaybackPosition(0.8), fast: true))
      let resolver = player.pendingSeekSettlement?.resolver
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.6
      )
      await drainMainActor()

      #expect(resolver?.resolvedOutcome == .settled)
      #expect(player.pendingSeekSettlement == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.currentTime == .seconds(36))
      #expect(abs(player.position - 0.6) < 0.000_001)
    }

    @Test
    func `No time watched point terminally times out absolute seek`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }

      try player.seek(to: .seconds(30), fast: true)
      let resolver = try #require(player.pendingSeekSettlement?.resolver)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.6
      )
      await drainMainActor()

      #expect(resolver.resolvedOutcome == .timedOut)
      #expect(player.pendingSeekSettlement == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.currentTime == .seconds(30))
    }

    @Test
    func `Seek end cannot overwrite an optimistic target with the stale paused getter`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(30), position: 0.5)
      )
      #expect(player.pendingSeekSettlement != nil)

      nativePoint = (30000, 0.5)
      player._pollPendingSeekForTesting()
      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(30), position: 0.5)
      )
      #expect(player.pendingSeekSettlement == nil)
    }

    @Test
    func `A changed pause sample cannot settle a video seek before its output point`() async throws {
      let player = makePausedSeekPlayer()
      player._seekOverridesForTesting.hasSelectedVideo = true
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekBaselineOverrideForTesting = { (2000, 2.0 / 60.0) }
      player._nativeSeekLandingOverrideForTesting = { (2001, 2.001 / 60.0) }
      let request = try player.requestSeek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      player._pollPendingSeekForTesting()
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)
      #expect(player.currentTime == .seconds(30))
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(30))
    }

    @Test
    func `A watched post-end point wins the paused fallback race`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 2.0 / 60.0) }

      try player.seek(to: .seconds(30), fast: true)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement != nil)

      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 29700,
        position: 0.495
      )
      await drainMainActor()

      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .milliseconds(29700), position: 0.495)
      )
      #expect(player.pendingSeekSettlement == nil)
    }

    @Test
    func `A paused fallback claim releases seek drain and rejects the late watched point`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (30000, 0.5) }
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(30))
      player.nextFrame()
      #expect(dispatched == [1])

      // The fallback consumed the exact monitor token under its mutex. A late
      // watched point from the same ended episode can neither settle twice nor
      // overwrite the fallback winner.
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 29700,
        position: 0.495
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(30))
      #expect(player.pendingFrameSteps.map(\.requestToken) == [1])
    }

    @Test
    func `Paused fallback and watched point have exactly one winner under contention`() async {
      let player = makePausedSeekPlayer()
      let monitor = player.nativeSeekMonitor
      let watchedDeliveries = Mutex(0)
      monitor.setHandler { _ in
        watchedDeliveries.withLock { $0 += 1 }
      }

      for iteration in 0..<100 {
        let token = monitor.stageCommand()
        monitor._noteSeekStartedForTesting()
        monitor._noteSeekEndedForTesting()
        let deliveriesBefore = watchedDeliveries.withLock { $0 }
        let candidate = NativeSeekLanding(
          token: token,
          timeMilliseconds: Int64(30000 + iteration),
          position: 0.5
        )

        let fallback = Task.detached {
          monitor.claimPausedFallback(candidate)
        }
        let watched = Task.detached {
          monitor._noteTimeUpdatedForTesting(
            timeMilliseconds: Int64(30000 + iteration),
            position: 0.5
          )
        }
        let claimed = await fallback.value
        await watched.value
        let watchedWins = watchedDeliveries.withLock { $0 - deliveriesBefore }

        #expect((claimed == nil ? 0 : 1) + watchedWins == 1)
      }
    }

    @Test
    func `A new position paired with the old time is not a coherent fallback landing`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 0.5) }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(30), position: 0.5)
      )
      #expect(player.pendingSeekSettlement != nil)
    }

    @Test
    func `Rapid seeks serialize and A landing cannot settle B`() async throws {
      let player = makePausedSeekPlayer()
      var dispatchedTimes: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }
      player._nativeSeekBaselineOverrideForTesting = { (2000, 2.0 / 60.0) }

      try player.seek(to: .seconds(30))
      let firstToken = try #require(player.pendingSeekSettlement?.nativeSeekToken)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      try player.seek(to: .seconds(40))
      let second = try #require(player.pendingSeekSettlement)
      #expect(second.nativeSeekToken != firstToken)
      #expect(second.baselineTimeMilliseconds == 2000)
      #expect(second.allowsPausedFallback == false)
      #expect(second.timelineRevision == nil)
      #expect(player.currentTime == .seconds(30))
      expectNoDifference(dispatchedTimes, [30000])

      // A is still the sole native owner. Its terminal point releases the lane
      // and publishes A's exact landing. B publishes only after its own native
      // dispatch succeeds.
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 30000,
        position: 0.5
      )
      await drainMainActor()

      #expect(player.pendingSeekSettlement?.nativeSeekToken == second.nativeSeekToken)
      #expect(player.currentTime == .seconds(40))
      expectNoDifference(dispatchedTimes, [30000, 40000])

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 2.0 / 3.0
      )
      await drainMainActor()
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(40))
      #expect(abs(player.position - (2.0 / 3.0)) < 0.000_001)
    }

    @Test
    func `Queued absolute fallback refreshes its baseline at dispatch`() async throws {
      try await verifyQueuedDispatchEvidence(.absolute)
    }

    @Test
    func `Queued known duration position fallback refreshes its baseline and target`() async throws {
      try await verifyQueuedDispatchEvidence(.knownDurationPosition)
    }

    @Test
    func `Queued unknown duration position fallback refreshes its baseline`() async throws {
      try await verifyQueuedDispatchEvidence(.unknownDurationPosition)
    }

    @Test
    func `Queued relative fallback rebases its target at dispatch`() async throws {
      try await verifyQueuedDispatchEvidence(.relative)
    }

    @Test
    func `A queued seek timeout stays quarantined across resume until drain`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      try player.seek(to: .seconds(30))
      let firstToken = try #require(player.pendingSeekSettlement?.nativeSeekToken)
      try player.seek(to: .seconds(40))
      let secondToken = try #require(player.pendingSeekSettlement?.nativeSeekToken)
      #expect(secondToken != firstToken)

      // Only A entered native code. Its exact watched landing releases the
      // single-flight slot and dispatches B without applying A over B's newer
      // optimistic publication.
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 2.0 / 3.0
      )
      await drainMainActor()

      #expect(player.pendingSeekSettlement?.nativeSeekToken == secondToken)
      #expect(player.currentTime == .seconds(40))

      // Timing out B's public settlement cannot release its dispatched monitor
      // episode. Resume retires the old frame request, but is not seek-drain
      // evidence and the replacement frame must remain queued.
      player._expirePendingSeekForTesting()
      player.nextFrame()
      #expect(dispatched.isEmpty)
      #expect(player.pendingFrameSteps.map(\.requestToken) == [1])

      player.prepareForPlaybackResumeBoundary()
      #expect(player.pendingFrameSteps.isEmpty)
      player.nextFrame()

      #expect(player.pendingSeekSettlement == nil)
      #expect(dispatched.isEmpty)
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 2.0 / 3.0
      )
      await drainMainActor()

      #expect(dispatched == [2])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
    }

    @Test
    func `A fallback landing derives position from time when position is invalid`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      // A sentinel position carries no contradictory evidence. The valid exact
      // time can settle and derive a coherent fraction from known duration.
      nativePoint = (30000, -.infinity)
      player._pollPendingSeekForTesting()

      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(30))
      #expect(abs(player.position - 0.5) < 0.000_001)
    }

    @Test
    func `Resume permanently disables paused fallback but preserves watched landing authority`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement?.allowsPausedFallback == true)

      player.resume()
      #expect(player.pendingSeekSettlement?.allowsPausedFallback == false)
      player._nativePlaybackStateOverrideForTesting = .paused
      nativePoint = (15000, 0.25)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)
      #expect(player.currentTime == .seconds(30))

      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 29700,
        position: 0.495
      )
      await drainMainActor()
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .milliseconds(29700))
      #expect(abs(player.position - 0.495) < 0.000_001)
    }

    @Test
    func `An externally observed paused-to-playing transition disables getter fallback`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement?.allowsPausedFallback == true)

      player.handleEvent(.stateChanged(.playing))
      #expect(player.pendingSeekSettlement?.allowsPausedFallback == false)
      player._nativePlaybackStateOverrideForTesting = .paused
      nativePoint = (30000, 0.5)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)

      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 29700,
        position: 0.495
      )
      await drainMainActor()
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .milliseconds(29700))
    }

    @Test
    func `Public playback seek commands are inert once shutdown begins`() async {
      let player = makePausedSeekPlayer()
      var nativeDispatches = 0
      player._nativeSetTimeOverrideForTesting = { _, _ in
        nativeDispatches += 1
        return 0
      }
      player._nativeSetPositionOverrideForTesting = { _, _ in
        nativeDispatches += 1
        return 0
      }
      player._nativeJumpTimeOverrideForTesting = { _ in
        nativeDispatches += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        nativeDispatches += 1
        return 0
      }
      player.isShutdown = true

      #expect(throws: VLCError.self) {
        try player.seek(to: .seconds(30))
      }
      #expect(throws: VLCError.self) {
        try player.seek(to: PlaybackPosition(0.5))
      }
      #expect(throws: VLCError.self) {
        try player.seek(by: .seconds(5))
      }
      #expect(player.seek(toPosition: PlaybackPosition(0.5)) == false)
      #expect(player.jump(by: .seconds(5)) == false)
      let request = player.requestJump(by: .seconds(5))
      #expect(request.initialOutcome == .rejected)
      #expect(await request.outcome == .rejected)
      #expect(throws: VLCError.self) {
        try player.play()
      }

      player.pause()
      player.resume()
      player.togglePlayPause()
      player.stop()

      #expect(nativeDispatches == 0)
      #expect(player.state == .paused)
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.pendingFrameSteps.isEmpty)
    }

    @Test
    func `A paused seek timeout retains its optimistic target`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 2.0 / 60.0) }
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      try player.seek(to: .seconds(30))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      player._expirePendingSeekForTesting()

      expectNoDifference(
        SeekLandingMirror(currentTime: player.currentTime, position: player.position),
        SeekLandingMirror(currentTime: .seconds(30), position: 0.5)
      )
      #expect(player.pendingSeekSettlement == nil)

      player.nextFrame()
      #expect(dispatched.isEmpty)
      player.prepareForPlaybackResumeBoundary()
      player.nextFrame()

      #expect(dispatched.isEmpty)
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 30000,
        position: 0.5
      )
      await drainMainActor()

      #expect(dispatched == [2])
    }

    @Test
    func `An unchanged getter can settle a legitimate same-target seek`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 2.0 / 60.0) }

      try player.seek(to: .seconds(2))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()

      #expect(player.currentTime == .seconds(2))
      #expect(player.pendingSeekSettlement == nil)
    }

    @Test
    func `Unknown duration position seek accepts a stable off target landing`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        currentTime: .seconds(2),
        position: 0.1,
        isSeekable: true
      )
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      player._nativeSeekBaselineOverrideForTesting = { (2000, 0.1) }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 0.1)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      #expect(player.seek(toPosition: PlaybackPosition(0.8), fast: true))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.pendingSeekSettlement != nil)

      nativePoint = (-1, 0.6)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)
      #expect(player.position == 0.8)
      player._pollPendingSeekForTesting()

      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(2))
      #expect(abs(player.position - 0.6) < 0.000_001)
    }

    @Test
    func `Rejected play keeps paused seek fallback eligible`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
      player._nativeSeekLandingOverrideForTesting = { nativePoint }

      try player.seek(to: .seconds(30), fast: true)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      #expect(player.activeNativeSeek?.allowsPausedFallback == true)

      player._nativePlayOverrideForTesting = { -1 }
      #expect(throws: VLCError.self) {
        try player.play()
      }
      #expect(player.activeNativeSeek?.allowsPausedFallback == true)

      nativePoint = (29000, 29.0 / 60.0)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement != nil)
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(29))
    }

    @Test
    func `Rejected direct resume preserves paused fallback`() async throws {
      for rejectedNativeState in [PlayerState.stopped, .idle] {
        let player = makePausedSeekPlayer()
        player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
        var nativePoint = (timeMilliseconds: Int64(2000), position: 2.0 / 60.0)
        player._nativeSeekLandingOverrideForTesting = { nativePoint }

        try player.seek(to: .seconds(30), fast: true)
        player.nativeSeekMonitor._noteSeekStartedForTesting()
        player.nativeSeekMonitor._noteSeekEndedForTesting()
        await drainMainActor()
        #expect(player.activeNativeSeek?.allowsPausedFallback == true)

        // The cached observable state is still paused, but a fresh native
        // read proves there is no resumable input. Rejection must not disable
        // the seek's paused-only reconciliation path.
        player._nativePlaybackStateOverrideForTesting = rejectedNativeState
        #expect(player.issueResume() == false)
        #expect(player.activeNativeSeek?.allowsPausedFallback == true)

        player._nativePlaybackStateOverrideForTesting = .paused
        nativePoint = (29000, 29.0 / 60.0)
        player._pollPendingSeekForTesting()
        #expect(player.pendingSeekSettlement != nil)
        player._pollPendingSeekForTesting()
        #expect(player.pendingSeekSettlement == nil)
        #expect(player.currentTime == .seconds(29))
      }
    }

    private func makePausedSeekPlayer() -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        currentTime: .seconds(2),
        duration: .seconds(60),
        position: 2.0 / 60.0,
        isSeekable: true
      )
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeSeekBaselineOverrideForTesting = { (2000, 2.0 / 60.0) }
      return player
    }

    private enum QueuedDispatchEvidenceCase: Equatable {
      case absolute
      case knownDurationPosition
      case unknownDurationPosition
      case relative
    }

    /// A's native landing moves from the enqueue-time clock (2 s) to 29 s.
    /// B must capture 29 s immediately before its own native call; otherwise
    /// two unchanged paused getter reads can falsely settle B using A's point.
    private func verifyQueuedDispatchEvidence(
      _ testCase: QueuedDispatchEvidenceCase
    )
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let hasKnownDuration = testCase != .unknownDurationPosition
      player._setStateForTesting(
        state: .paused,
        currentTime: .seconds(2),
        duration: hasKnownDuration ? .seconds(60) : nil,
        position: hasKnownDuration ? 2.0 / 60.0 : 0.02,
        isSeekable: true
      )
      player._nativePlaybackStateOverrideForTesting = .paused
      var nativePoint = (
        timeMilliseconds: Int64(2000),
        position: hasKnownDuration ? 2.0 / 60.0 : 0.02
      )
      player._nativeSeekBaselineOverrideForTesting = { nativePoint }
      player._nativeSeekLandingOverrideForTesting = { nativePoint }
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      try player.seek(to: .seconds(20), fast: true)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      switch testCase {
      case .absolute:
        try player.seek(to: .seconds(40), fast: true)
      case .knownDurationPosition, .unknownDurationPosition:
        #expect(player.seek(toPosition: PlaybackPosition(0.8), fast: true))
      case .relative:
        #expect(player.jump(by: .seconds(10)))
      }
      #expect(player.pendingSeekSettlement?.baselineTimeMilliseconds == 2000)

      if testCase == .knownDurationPosition {
        // Duration metadata may settle while B waits behind A. Fractional B
        // must derive its time target from the dispatch-time duration, not the
        // 60-second value visible when it entered the queue.
        player.duration = .seconds(100)
      }
      nativePoint = (
        29000,
        testCase == .knownDurationPosition
          ? 0.29
          : (hasKnownDuration ? 29.0 / 60.0 : 0.29)
      )
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 29000,
        position: nativePoint.position
      )
      await drainMainActor()

      let pending = try #require(player.pendingSeekSettlement)
      #expect(pending.baselineTimeMilliseconds == 29000)
      switch testCase {
      case .absolute:
        #expect(pending.requestedTimeMilliseconds == 40000)
      case .knownDurationPosition:
        #expect(pending.requestedTimeMilliseconds == 80000)
      case .unknownDurationPosition:
        #expect(pending.requestedTimeMilliseconds == nil)
      case .relative:
        #expect(pending.requestedTimeMilliseconds == 39000)
      }

      // Absolute and position setters do not run libVLC under these test
      // overrides, so supply the start they would synchronously emit. The
      // relative override has already consumed its exact staged reservation.
      if testCase != .relative {
        player.nativeSeekMonitor._noteSeekStartedForTesting()
      }
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      player._pollPendingSeekForTesting()

      #expect(player.pendingSeekSettlement != nil)
      switch testCase {
      case .absolute:
        #expect(player.currentTime == .seconds(40))
      case .relative:
        #expect(player.currentTime == .seconds(39))
      case .knownDurationPosition:
        #expect(abs(player.position - 0.8) < 0.000_001)
        #expect(player.currentTime == .seconds(80))
      case .unknownDurationPosition:
        #expect(abs(player.position - 0.8) < 0.000_001)
        nativePoint = (-1, 0.45)
        player._pollPendingSeekForTesting()
        #expect(player.pendingSeekSettlement != nil)
        player._pollPendingSeekForTesting()
        #expect(player.pendingSeekSettlement == nil)
        #expect(player.currentTime == .seconds(29))
        #expect(abs(player.position - 0.45) < 0.000_001)
        return
      }

      nativePoint = switch testCase {
      case .absolute: (40000, 40.0 / 60.0)
      case .knownDurationPosition: (80000, 0.8)
      case .relative: (39000, 39.0 / 60.0)
      case .unknownDurationPosition: fatalError("handled above")
      }
      player._pollPendingSeekForTesting()
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .milliseconds(nativePoint.timeMilliseconds))
    }

    private func drainMainActor() async {
      for _ in 0..<20 {
        await Task.yield()
      }
    }
  }
}
