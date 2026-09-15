@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekOutputEvidenceTests {
    @Test(arguments: [29900, 30000, 30033, 30100])
    func `Video evidence checks the precise target and publishes the observed frame`(landedMilliseconds: Int64) async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 2.0 / 60.0) }
      let request = try player.requestSeek(to: .seconds(30))
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
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

    @Test
    func `Late video corrects a timed out seek without resolving it again`() async throws {
      let player = makePausedSeekPlayer()
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekLandingOverrideForTesting = { (2000, 2.0 / 60.0) }
      let request = try player.requestSeek(to: .seconds(30), fast: true)
      let token = try #require(player.activeNativeSeek?.command.nativeSeekToken)
      player.nativeSeekMonitor.requireVideoOutput(for: token)
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player._expirePendingSeekForTesting()
      #expect(await request.outcome == .timedOut)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 30000, position: 0.5)
      await drainMainActor()
      #expect(player.activeNativeSeek != nil)
      player.nativeSeekMonitor._noteVideoOutputForTesting(timeMilliseconds: 25000, position: 25.0 / 60)
      await drainMainActor()
      #expect(player.currentTime == .seconds(25))
      #expect(player.activeNativeSeek == nil)
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
