@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekOutputEvidenceTests {
    @Test(arguments: [29900, 30000, 30033, 30100])
    func `Video evidence checks the precise target and publishes the observed frame`(landedMilliseconds: Int64) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (30000, 0.5) }
      let request = try player.requestSeek(to: .seconds(30))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      player.pollPausedNativeSeek(token: token)
      player.pollPausedNativeSeek(token: token)
      #expect(player.pendingSeekSettlement != nil)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)
      player.nativeSeekMonitor._noteVideoOutputForTesting(
        timeMilliseconds: landedMilliseconds, position: Double(landedMilliseconds) / 60000
      )
      await drainMainActor()
      #expect(await request.outcome == ((30000...30033).contains(landedMilliseconds) ? .settled : .inaccurate))
      #expect(player.currentTime == .milliseconds(landedMilliseconds))
      #expect(player.activeNativeSeek == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
    }

    @Test(arguments: [false, true])
    func `Late video corrects a timed out seek without resolving it again`(timeoutBeforeEnd: Bool) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 2.0 / 60.0) }
      let request = try player.requestSeek(to: .seconds(30), fast: true)
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      if timeoutBeforeEnd {
        player._expirePendingSeekForTesting()
      }
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      if !timeoutBeforeEnd {
        player._expirePendingSeekForTesting()
      }
      await drainMainActor()
      #expect(await request.outcome == .timedOut)
      #expect(player.activeNativeSeek == nil)
      #expect(player.lateNativeSeekObservation != nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 25000, position: 25.0 / 60)
      await drainMainActor()
      #expect(player.currentTime == .seconds(25))
      #expect(player.activeNativeSeek == nil)
      #expect(await request.outcome == .timedOut)
    }

    @Test(arguments: [false, true])
    func `Late paused audio proof drains a timed out seek`(selectVideoBeforeDeadline: Bool) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._seekOverridesForTesting.hasSelectedVideo = false
      var point: (Int64, Double) = (2000, 2.0 / 60)
      player._nativeSeekLandingOverrideForTesting = { point }
      let request = try player.requestSeek(to: .seconds(30), fast: true)
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      #expect(player.activeNativeSeek?.requiresVideoOutput == false)
      if selectVideoBeforeDeadline {
        player._seekOverridesForTesting.hasSelectedVideo = true
      }
      player._expirePendingSeekForTesting()
      #expect(await request.outcome == .timedOut)
      player._seekOverridesForTesting.hasSelectedVideo = true
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      point = (25000, 25.0 / 60)
      player.pollPausedNativeSeek(token: token)
      player.pollPausedNativeSeek(token: token)
      #expect(player.currentTime == .seconds(25))
      #expect(player.activeNativeSeek == nil)
      #expect(await request.outcome == .timedOut)
    }

    @Test
    func `Expired video observation releases a queued seek without false settlement`() async throws {
      let player = makePausedSeekPlayer()
      var dispatched: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { time, _ in dispatched.append(time); return 0 }
      let first = try player.requestSeek(to: .seconds(30))
      let firstToken = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: firstToken)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      let second = try player.requestSeek(to: .seconds(12))
      player.expireActiveNativeSeek(nativeSeekToken: firstToken, playbackGeneration: nil)
      await drainMainActor()
      #expect(dispatched == [30000, 12000])
      #expect(await first.outcome != .settled)
      #expect(player.lateNativeSeekObservation == nil)
      let secondToken = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      #expect(secondToken != firstToken)
      player.nativeSeekMonitor.requireVideoOutput(for: secondToken)
      // A delayed old frame before the successor's seek-end cannot land it.
      player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      #expect(player.activeNativeSeek?.command.nativeSeekToken == secondToken)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 12000, position: 0.2)
      await drainMainActor()
      #expect(await second.outcome == .settled)
      #expect(player.currentTime == .seconds(12))
    }

    @Test(arguments: [false, true])
    func `A new causal boundary retires late video ownership`(externalSeek: Bool) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      let request = try player.requestSeek(to: .seconds(30))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player._expirePendingSeekForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      #expect(player.lateNativeSeekObservation != nil)
      if externalSeek {
        player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      } else {
        let dispatch = player.nativeSeekMonitor._requestFrameStepForTesting(
          requestID: 42, frameGeneration: player.nativeSeekMonitor.frameGeneration,
          dispatch: { .accepted }
        )
        #expect(dispatch == .accepted)
      }
      player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 25000, position: 25.0 / 60)
      await drainMainActor()
      #expect(player.currentTime != .seconds(25))
      #expect(await request.outcome == .timedOut)
    }

    @Test(arguments: [false, true], [false, true])
    func `An unstarted successor preserves the prior late output`(unprovenSuccess: Bool, outputDuringSetter: Bool) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      let request = try player.requestSeek(to: .seconds(30))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player._expirePendingSeekForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      #expect(player.lateNativeSeekObservation != nil)
      player._nativeSetTimeOverrideForTesting = { _, _ in
        if outputDuringSetter {
          player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 25000, position: 25.0 / 60)
        }
        if unprovenSuccess, let staged = player.activeNativeSeek?.command.nativeSeekToken {
          // Remove the staged reservation before the DEBUG start is supplied:
          // the setter returns zero but there is no causal start proof.
          player.nativeSeekMonitor.cancelStagedCommand(staged)
          return 0
        }
        return -1
      }
      let successor = try? player.requestSeek(to: .seconds(12))
      if unprovenSuccess {
        let successor = try #require(successor)
        #expect(await successor.outcome == .superseded)
      } else {
        #expect(successor == nil)
      }
      if !outputDuringSetter {
        player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 25000, position: 25.0 / 60)
      }
      await drainMainActor()
      #expect(player.currentTime == .seconds(25))
      #expect(player.activeNativeSeek == nil)
      #expect(player.lateNativeSeekObservation == nil)
      #expect(await request.outcome == .timedOut)
    }

    @Test
    func `A video seek keeps its output requirement after track deselection`() async throws {
      let player = makePausedSeekPlayer()
      player._seekOverridesForTesting.hasSelectedVideo = true
      player._seekOverridesForTesting.supportsVideoOutputEvidence = true
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (30000, 0.5) }
      let request = try player.requestSeek(to: .seconds(30))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player._seekOverridesForTesting.hasSelectedVideo = false
      player._expirePendingSeekForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      player.pollPausedNativeSeek(token: token)
      player.pollPausedNativeSeek(token: token)
      #expect(player.activeNativeSeek?.requiresVideoOutput == true)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(await request.outcome == .timedOut)
    }

    @Test(arguments: [NativeFrameRequestDispatch.busy, .unavailable])
    func `A rejected frame request preserves the prior late output`(disposition: NativeFrameRequestDispatch) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      let request = try player.requestSeek(to: .seconds(30))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player._expirePendingSeekForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      _ = player.nativeSeekMonitor._requestFrameStepForTesting(
        requestID: 42, frameGeneration: player.nativeSeekMonitor.frameGeneration,
        dispatch: { disposition }
      )
      player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 25000, position: 25.0 / 60)
      await drainMainActor()
      #expect(player.currentTime == .seconds(25))
      #expect(await request.outcome == .timedOut)
    }

    /// Before a paused seek's first output libVLC can answer the getter from
    /// the input's last reported time. That is the pre-seek position read back
    /// a few milliseconds off the frozen output clock, not a landing.
    @Test
    func `A stale paused read beside the baseline does not settle a far seek`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._seekOverridesForTesting.hasSelectedVideo = false
      player._nativeSeekLandingOverrideForTesting = { (1981, 1.981 / 60) }

      let request = try player.requestSeek(to: .seconds(20))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      player.pollPausedNativeSeek(token: token)
      player.pollPausedNativeSeek(token: token)

      #expect(player.currentTime == .seconds(20))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      #expect(player.activeNativeSeek?.command.nativeSeekToken == token)

      // The same stable pair is a landing once it is clear of the baseline.
      player._nativeSeekLandingOverrideForTesting = { (19000, 19.0 / 60) }
      player.pollPausedNativeSeek(token: token)
      player.pollPausedNativeSeek(token: token)
      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(19))
    }

    /// With no output a paused input publishes no point until resume. A getter
    /// that keeps answering with the pre-seek position must not hold the lane
    /// for that long: the ended seek settles on its published target.
    @Test(arguments: [2000, 1981] as [Int64])
    func `A paused clock that stays stale settles on the target and frees the lane`(
      staleMilliseconds: Int64
    ) async throws {
      let player = makePausedSeekPlayer()
      var dispatchedTargets: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTargets.append(milliseconds)
        return 0
      }
      player._seekOverridesForTesting.hasSelectedVideo = false
      player._nativeSeekLandingOverrideForTesting = {
        (staleMilliseconds, Double(staleMilliseconds) / 60000)
      }

      let first = try player.requestSeek(to: .seconds(20))
      let second = try player.requestSeek(to: .seconds(40))
      #expect(dispatchedTargets == [20000])
      player.nativeSeekMonitor._noteSeekEndedForTesting()

      #expect(await first.outcome == .superseded)
      // The queued successor dispatches as soon as the stale bound releases
      // the first episode, well inside the two-second observation window.
      #expect(try await poll(timeout: .seconds(1.5)) { dispatchedTargets == [20000, 40000] })
      #expect(player.currentTime == .seconds(40))

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      #expect(await second.outcome == .settled)
      #expect(player.currentTime == .seconds(40))
      #expect(abs(player.position - 40.0 / 60) < 0.000_001)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
    }

    /// The jitter window only rejects reads beside the baseline of a far
    /// request. An honest off-target landing still publishes what was observed,
    /// and a request aimed inside the window keeps the plain changed-read rule.
    @Test(arguments: [(30000, 25000), (2300, 2250)] as [(Int64, Int64)])
    func `An honest paused landing settles on the observed time`(
      targetMilliseconds: Int64,
      landedMilliseconds: Int64
    ) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._seekOverridesForTesting.hasSelectedVideo = false
      player._nativeSeekLandingOverrideForTesting = {
        (landedMilliseconds, Double(landedMilliseconds) / 60000)
      }

      let request = try player.requestSeek(to: .milliseconds(targetMilliseconds), fast: true)
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await drainMainActor()
      player.pollPausedNativeSeek(token: token)
      player.pollPausedNativeSeek(token: token)

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .milliseconds(landedMilliseconds))
      #expect(player.activeNativeSeek == nil)
    }

    private func drainMainActor() async {
      for _ in 0..<20 {
        await Task.yield()
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
  }
}
