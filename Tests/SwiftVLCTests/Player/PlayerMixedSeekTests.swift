@testable import SwiftVLC
import CustomDump
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerMixedSeekTests {
    @Test(arguments: ["time", "strict-position", "raw-position"], [(false, false), (false, true), (true, false), (true, true)])
    func `Strict skips extend queued scrub intent after its deadline`(
      source: String, scenario: (expired: Bool, fast: Bool)
    )
      async throws {
      let (expired, fast) = scenario
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing, isPlaybackRequestedActive: true, currentTime: .seconds(10),
        duration: .seconds(100), position: 0.1, isSeekable: true
      )
      var dispatchedTimes: [Int64] = []
      var dispatchedFast: [Bool] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, fast in
        dispatchedTimes.append(milliseconds)
        dispatchedFast.append(fast)
        return 0
      }
      _ = try player.requestSeek(to: .seconds(80))
      let scrub = switch source {
      case "time": try player.requestSeek(to: .seconds(50))
      case "strict-position": try player.requestSeek(to: PlaybackPosition(0.5))
      default: player.requestSeek(toPosition: PlaybackPosition(0.5))
      }
      if expired {
        player._expirePendingSeekForTesting()
        #expect(await scrub.outcome == .timedOut)
      }
      _ = try player.requestSeek(by: .seconds(-15))
      let final = try player.requestSeek(by: .seconds(-5), fast: fast)
      player.duration = .seconds(60)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(timeMilliseconds: 78000, position: 0.78)
      for _ in 0..<30 {
        await Task.yield()
      }

      let expected: Int64 = source == "raw-position" ? 10000 : 30000
      expectNoDifference(dispatchedTimes, [80000, expected])
      expectNoDifference(dispatchedFast, [false, fast])
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: expected, position: Double(expected) / 60000
      )
      #expect(await final.outcome == .settled)
    }
  }
}
