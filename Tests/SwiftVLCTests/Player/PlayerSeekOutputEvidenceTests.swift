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

    @Test
    func `Late paused audio proof drains a timed out seek`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      var point: (Int64, Double) = (2000, 2.0 / 60)
      player._nativeSeekLandingOverrideForTesting = { point }
      let request = try player.requestSeek(to: .seconds(30), fast: true)
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player._expirePendingSeekForTesting()
      #expect(await request.outcome == .timedOut)
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
