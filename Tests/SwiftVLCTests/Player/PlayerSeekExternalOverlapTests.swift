@testable import SwiftVLC
import CustomDump
import Foundation
import Synchronization
import Testing

extension Integration {
  /// A native seek the wrapper did not issue (an A-B loop bounce, a short
  /// navigation jump) that overlaps wrapper seek work. Its end and point can
  /// never settle a wrapper request, but they must drain: the lane and the
  /// raw clock reopen at the first watched point after the coalesced end.
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekExternalOverlapTests {
    @Test
    func `External start overlapping wrapper work drains without settling wrapper requests`() async {
      let player = makePlayingPlayer()
      let bridge = player.eventBridge
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let playbackGeneration = player.sessionGeneration
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      await drainMainActor()

      #expect(await a.outcome == .superseded)
      #expect(await b.outcome == .superseded)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)

      let c = player.requestJump(by: .seconds(30))
      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.queuedNativeSeek?.externalEpoch == 1)

      // While the overlap is unresolved a raw sample cannot be attributed.
      bridge._broadcastForTesting(
        .timeChanged(.seconds(12)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: playbackGeneration
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(10))

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      // The end alone proves nothing has landed yet.
      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 25000,
        position: 0.25
      )
      await drainMainActor()

      // The point belongs to wrapper A or external e1; it settles neither
      // wrapper request, but it is observed playback and releases C.
      expectNoDifference(dispatchedOffsets, [10000, 30000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 3)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 55000,
        position: 0.55
      )
      await drainMainActor()
      #expect(await c.outcome == .settled)
      #expect(player.currentTime == .seconds(55))
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

      // The raw clock is live again for the rest of the session.
      bridge._broadcastForTesting(
        .timeChanged(.seconds(56)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: playbackGeneration
      )
      for _ in 0..<50 where player.currentTime != .seconds(56) {
        await Task.yield()
      }
      #expect(player.currentTime == .seconds(56))
    }

    /// With no wrapper intent waiting, the drained overlap publishes its
    /// observed point and reopens both the raw clock and the lane.
    @Test
    func `Overlapping external starts publish their landing and reopen the raw clock`() async {
      let player = makePlayingPlayer()
      let bridge = player.eventBridge
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let playbackGeneration = player.sessionGeneration
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      #expect(player.currentTime == .seconds(20))
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

      bridge._broadcastForTesting(
        .timeChanged(.seconds(21)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: playbackGeneration
      )
      for _ in 0..<50 where player.currentTime != .seconds(21) {
        await Task.yield()
      }
      #expect(player.currentTime == .seconds(21))

      let request = player.requestJump(by: .seconds(5))
      expectNoDifference(dispatchedOffsets, [5000])
      #expect(request.initialOutcome == .pending)
    }

    private func makePlayingPlayer() -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100),
        position: 0.1,
        isSeekable: true
      )
      return player
    }

    private func drainMainActor() async {
      for _ in 0..<30 {
        await Task.yield()
      }
    }
  }
}
