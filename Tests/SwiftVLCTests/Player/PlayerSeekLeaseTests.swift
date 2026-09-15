@testable import SwiftVLC
import CustomDump
import Foundation
import Synchronization
import Testing

private struct SeekSingleFlightMirror: Equatable {
  let dispatchedOffsets: [Int64]
  let activeToken: UInt64?
  let queuedToken: UInt64?
  let pendingToken: UInt64?
  let currentTime: Duration
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekLeaseTests {
    @Test
    func `A active B C queued dispatches only A and aggregate C`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      let c = player.requestJump(by: .seconds(30))

      #expect(await a.outcome == .superseded)
      #expect(await b.outcome == .superseded)
      expectNoDifference(
        SeekSingleFlightMirror(
          dispatchedOffsets: dispatchedOffsets,
          activeToken: player.activeNativeSeek?.command.nativeSeekToken,
          queuedToken: player.queuedNativeSeek?.nativeSeekToken,
          pendingToken: player.pendingSeekSettlement?.nativeSeekToken,
          currentTime: player.currentTime
        ),
        SeekSingleFlightMirror(
          dispatchedOffsets: [10000],
          activeToken: 1,
          queuedToken: 3,
          pendingToken: 3,
          currentTime: .seconds(10)
        )
      )

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(dispatchedOffsets, [10000, 50000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 3)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.currentTime == .seconds(20))

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 70000,
        position: 0.7
      )
      #expect(await c.outcome == .settled)
      #expect(player.currentTime == .seconds(70))
    }

    @Test
    func `A landing cannot settle or overwrite optimistic C`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      try player.seek(to: .seconds(20))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      try player.seek(to: .seconds(40))
      let cToken = try #require(player.pendingSeekSettlement?.nativeSeekToken)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(
        SeekSingleFlightMirror(
          dispatchedOffsets: dispatchedTimes,
          activeToken: player.activeNativeSeek?.command.nativeSeekToken,
          queuedToken: player.queuedNativeSeek?.nativeSeekToken,
          pendingToken: player.pendingSeekSettlement?.nativeSeekToken,
          currentTime: player.currentTime
        ),
        SeekSingleFlightMirror(
          dispatchedOffsets: [20000, 40000],
          activeToken: cToken,
          queuedToken: nil,
          pendingToken: cToken,
          currentTime: .seconds(40)
        )
      )
    }

    @Test
    func `A timeout tombstones ownership and blocks C until native drain`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      player._expirePendingSeekForTesting()
      #expect(await a.outcome == .timedOut)
      #expect(player.activeNativeSeek?.isTombstoned == true)

      let c = player.requestJump(by: .seconds(20))
      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.queuedNativeSeek?.nativeSeekToken == 2)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(dispatchedOffsets, [10000, 20000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 2)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 30000,
        position: 0.3
      )
      #expect(await c.outcome == .settled)
    }

    @Test
    func `No time watched point drains timed out A and dispatches B`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      player._expirePendingSeekForTesting()
      #expect(await a.outcome == .timedOut)
      let b = player.requestJump(by: .seconds(20))
      #expect(player.activeNativeSeek?.isTombstoned == true)
      expectNoDifference(dispatchedOffsets, [10000])

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.25
      )
      await drainMainActor()

      expectNoDifference(dispatchedOffsets, [10000, 20000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 2)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 30000,
        position: 0.3
      )
      #expect(await b.outcome == .settled)
    }

    @Test
    func `Relative override full callback sequence creates no phantom drain`() async {
      let player = makePlayingPlayer()
      var dispatches: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatches.append(offset)
        player.nativeSeekMonitor._noteSeekStartedForTesting()
        player.nativeSeekMonitor._noteSeekEndedForTesting()
        player.nativeSeekMonitor._noteTimeUpdatedForTesting(
          timeMilliseconds: 20000 + Int64(dispatches.count) * 10000,
          position: 0.2 + Double(dispatches.count) * 0.1
        )
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      await drainMainActor()
      #expect(await a.outcome == .settled)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

      let b = player.requestJump(by: .seconds(20))
      await drainMainActor()
      #expect(await b.outcome == .settled)
      expectNoDifference(dispatches, [10000, 20000])
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
    }

    @Test
    func `Superseded A native deadline tombstones A without releasing C`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      #expect(await a.outcome == .superseded)

      player._expireActiveNativeSeekForTesting()
      #expect(player.activeNativeSeek?.isTombstoned == true)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 2)
      expectNoDifference(dispatchedOffsets, [10000])

      let c = player.requestJump(by: .seconds(30))
      #expect(await b.outcome == .superseded)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 3)
      expectNoDifference(dispatchedOffsets, [10000])

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(dispatchedOffsets, [10000, 50000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 3)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 70000,
        position: 0.7
      )
      #expect(await c.outcome == .settled)
    }

    @Test
    func `Queued B restarts a fresh settlement deadline at native dispatch`() async {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))

      #expect(await a.outcome == .superseded)
      #expect(player.activeNativeSeek?.deadlineTask != nil)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 2)
      #expect(player.pendingSeekSettlement?.nativeSeekToken == 2)
      #expect(player.pendingSeekSettlement?.deadlinePhase == .queued)
      #expect(player.pendingSeekSettlement?.timeoutTask != nil)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      #expect(player.activeNativeSeek?.command.nativeSeekToken == 2)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.pendingSeekSettlement?.nativeSeekToken == 2)
      #expect(player.pendingSeekSettlement?.deadlinePhase == .dispatched)
      #expect(player.pendingSeekSettlement?.timeoutTask != nil)
      #expect(b.initialOutcome == .pending)

      // Model the cancelled queue-wait task resuming on the main actor just
      // after dispatch. Its captured phase cannot consume B's fresh window.
      player._expirePendingSeekForTesting(deadlinePhase: .queued)
      #expect(player.pendingSeekSettlement?.nativeSeekToken == 2)
      #expect(b.initialOutcome == .pending)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 0.4
      )
      #expect(await b.outcome == .settled)
    }

    @Test
    func `Queued observation times out but its intent remains until replaced`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      #expect(await a.outcome == .superseded)
      #expect(player.pendingSeekSettlement?.deadlinePhase == .queued)

      player._expirePendingSeekForTesting()

      #expect(await b.outcome == .timedOut)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 2)
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 1)
      #expect(player.activeNativeSeek?.isTombstoned == false)
      expectNoDifference(dispatchedOffsets, [10000])

      let c = player.requestJump(by: .seconds(30))
      #expect(c.initialOutcome == .pending)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 3)
      expectNoDifference(dispatchedOffsets, [10000])
    }

    @Test
    func `External start overlapping wrapper work remains fail closed until reset`() async {
      let player = makePlayingPlayer()
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

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 25000,
        position: 0.25
      )
      await drainMainActor()

      // The untagged end/point may belong either to wrapper A or external e1.
      // It cannot release C, even if repeated or allowed to age.
      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 3)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(c.initialOutcome == .pending)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 0.4
      )
      await drainMainActor()
      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)

      player.handleEvent(.stateChanged(.stopped))
      #expect(await c.outcome == .superseded)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.queuedNativeSeek == nil)
    }

    @Test
    func `Delayed wrapper landing cannot cross a synchronous external epoch`() async throws {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let captured = Mutex<NativeSeekLanding?>(nil)
      player.nativeSeekMonitor.setHandler { landing in
        captured.withLock { $0 = landing }
      }

      let request = player.requestJump(by: .seconds(10))
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let delayedLanding = try #require(captured.withLock { $0 })

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 1)
      player.nativeSeekDidLand(delayedLanding)

      #expect(await request.outcome == .superseded)
      #expect(player.currentTime == .seconds(10))
      #expect(abs(player.position - 0.1) < 0.000_001)
      #expect(player.activeNativeSeek == nil)
    }

    @Test
    func `Queued epoch check happens before reordered external MainActor delivery`() async {
      let player = makePlayingPlayer()
      let queuedToken = player.nativeSeekMonitor.reserveCommand()
      let queuedEpoch = player.nativeSeekMonitor.externalSeekEpoch

      // Complete e1 synchronously on the monitor while its start and drain
      // notifications remain independently queued for MainActor delivery.
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )

      #expect(player.nativeSeekMonitor.externalSeekEpoch == queuedEpoch + 1)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(!player.nativeSeekMonitor.stageReservedCommandIfIdle(
        queuedToken,
        expectedExternalEpoch: queuedEpoch
      ))

      player.nativeSeekMonitor.cancelReservedCommand(queuedToken)
      await drainMainActor()
    }

    @Test
    func `Queued wrapper cannot stage from reordered drain before external start delivery`() async throws {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      #expect(await a.outcome == .superseded)
      await drainMainActor()

      let wrapperLanding = Mutex<NativeSeekLanding?>(nil)
      let externalStart = Mutex<NativeSeekStart?>(nil)
      let externalLanding = Mutex<NativeExternalSeekLanding?>(nil)
      player.nativeSeekMonitor.setHandler { landing in
        wrapperLanding.withLock { $0 = landing }
      }
      player.nativeSeekMonitor.setSeekStartedHandler { start in
        externalStart.withLock { $0 = start }
      }
      player.nativeSeekMonitor.setExternalSeekLandingHandler { landing in
        externalLanding.withLock { $0 = landing }
      }
      player.nativeSeekMonitor.setSeekDrainAvailabilityHandler {}
      defer { player.configureNativeSeekMonitor() }

      // A drains on the callback thread, but its landing and drain-available
      // deliveries remain held. Before MainActor sees either, e1 completes
      // and synchronously advances the monitor epoch from zero to one.
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )

      let delayedWrapperLanding = try #require(wrapperLanding.withLock { $0 })
      let delayedExternalStart = try #require(externalStart.withLock { $0 })
      let delayedExternalLanding = try #require(externalLanding.withLock { $0 })
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 1)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

      // Deliver drain availability first, then A's older landing, and only
      // afterward the e1 start notification. B still carries epoch zero and
      // must be superseded without ever crossing the atomic staging gate.
      player.nativeSeekDrainDidClear()
      player.nativeSeekDidLand(delayedWrapperLanding)
      #expect(await b.outcome == .superseded)
      player.nativeSeekDidStart(delayedExternalStart)
      player.nativeExternalSeekDidLand(delayedExternalLanding)

      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.currentTime == .seconds(33))
    }

    @Test
    func `Resume keeps a timed out tombstone until watched native drain`() async {
      let player = makePlayingPlayer()
      player._nativePlaybackStateOverrideForTesting = .paused
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      let a = player.requestJump(by: .seconds(10))
      player._expirePendingSeekForTesting()
      #expect(await a.outcome == .timedOut)
      let c = player.requestJump(by: .seconds(20))
      expectNoDifference(dispatchedOffsets, [10000])

      player.prepareForPlaybackResumeBoundary()

      expectNoDifference(dispatchedOffsets, [10000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 1)
      #expect(player.activeNativeSeek?.isTombstoned == true)
      #expect(player.queuedNativeSeek?.nativeSeekToken == 2)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(dispatchedOffsets, [10000, 20000])
      #expect(player.activeNativeSeek?.command.nativeSeekToken == 2)
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 30000,
        position: 0.3
      )
      #expect(await c.outcome == .settled)
    }

    @Test
    func `Relative C after absolute B normalizes to Bs optimistic target`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      var dispatchedOffsets: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      try player.seek(to: .seconds(20))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      try player.seek(to: .seconds(40))
      #expect(player.jump(by: .seconds(10)))
      #expect(player.currentTime == .seconds(20))
      #expect(player.queuedNativeSeek?.timelineRevision == nil)
      expectNoDifference(dispatchedTimes, [20000])
      #expect(dispatchedOffsets.isEmpty)

      // A lands away from its optimistic target. Dispatching C as +10 from
      // this point would land at 28 seconds and contradict the published 50.
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 18000,
        position: 0.18
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [20000, 50000])
      #expect(dispatchedOffsets.isEmpty)
      #expect(player.currentTime == .seconds(50))
    }

    @Test(arguments: [
      (duration: 100, expected: 90),
      (duration: 40, expected: 40)
    ])
    func `Position then relative resolves and clamps using dispatch time duration`(
      testCase: (duration: Int64, expected: Int64)
    )
      async {
      let player = makePlayingPlayer()
      player.duration = .seconds(60)
      var dispatchedTimes: [Int64] = []
      var dispatchedPositions: [Double] = []
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      player._nativeSetPositionOverrideForTesting = { position, _ in
        dispatchedPositions.append(position)
        return 0
      }
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      _ = player.requestJump(by: .seconds(1))
      #expect(player.seek(toPosition: PlaybackPosition(0.8)))
      #expect(player.jump(by: .seconds(10)))
      player.duration = .seconds(testCase.duration)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 11000,
        position: 0.11
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [testCase.expected * 1000])
      #expect(dispatchedPositions.isEmpty)
      #expect(player.currentTime == .seconds(testCase.expected))
    }

    @Test(arguments: [
      (duration: 200, expected: 110),
      (duration: 80, expected: 80)
    ])
    func `Absolute then relative clamps once using dispatch time duration`(
      testCase: (duration: Int64, expected: Int64)
    )
      async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      _ = player.requestJump(by: .seconds(1))
      try player.seek(to: .seconds(90))
      #expect(player.jump(by: .seconds(20)))
      player.duration = .seconds(testCase.duration)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 11000,
        position: 0.11
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [testCase.expected * 1000])
      #expect(player.currentTime == .seconds(testCase.expected))
    }

    @Test
    func `Absolute C replaces queued relative B without native B dispatch`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      var dispatchedOffsets: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }

      try player.seek(to: .seconds(20))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      let b = player.requestJump(by: .seconds(20))
      try player.seek(to: .seconds(50))

      #expect(await b.outcome == .superseded)
      expectNoDifference(dispatchedTimes, [20000])
      #expect(dispatchedOffsets.isEmpty)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [20000, 50000])
      #expect(dispatchedOffsets.isEmpty)
    }

    @Test
    func `Position replaces a queued absolute relative composition`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      var dispatchedPositions: [Double] = []
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }
      player._nativeSetPositionOverrideForTesting = { position, _ in
        dispatchedPositions.append(position)
        return 0
      }

      _ = player.requestJump(by: .seconds(1))
      try player.seek(to: .seconds(40))
      let relative = player.requestJump(by: .seconds(10))
      #expect(player.seek(toPosition: PlaybackPosition(0.75)))
      #expect(await relative.outcome == .superseded)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 11000,
        position: 0.11
      )
      await drainMainActor()

      #expect(dispatchedTimes.isEmpty)
      expectNoDifference(dispatchedPositions, [0.75])
    }

    @Test
    func `Absolute replaces a queued position relative composition`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      var dispatchedPositions: [Double] = []
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }
      player._nativeSetPositionOverrideForTesting = { position, _ in
        dispatchedPositions.append(position)
        return 0
      }

      _ = player.requestJump(by: .seconds(1))
      #expect(player.seek(toPosition: PlaybackPosition(0.4)))
      let relative = player.requestJump(by: .seconds(10))
      try player.seek(to: .seconds(75))
      #expect(await relative.outcome == .superseded)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 11000,
        position: 0.11
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [75000])
      #expect(dispatchedPositions.isEmpty)
    }

    @Test
    func `Stop supersedes both scheduler layers and rejects stale callbacks`() async {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let outgoingGeneration = player.nativeSeekMonitor._timelineGenerationForTesting

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      player._nativePlaybackStateOverrideForTesting = .idle
      player.stop()

      #expect(await a.outcome == .superseded)
      #expect(await b.outcome == .superseded)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.pendingSeekSettlement == nil)

      player.nativeSeekMonitor._noteSeekEndedForTesting(
        timelineGeneration: outgoingGeneration
      )
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2,
        timelineGeneration: outgoingGeneration
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(10))
    }

    @Test
    func `Media replacement supersedes both layers and frees the next session lane`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }
      let outgoingGeneration = player.nativeSeekMonitor._timelineGenerationForTesting

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      player.resetMediaDerivedState()

      #expect(await a.outcome == .superseded)
      #expect(await b.outcome == .superseded)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

      player.nativeSeekMonitor._noteSeekEndedForTesting(
        timelineGeneration: outgoingGeneration
      )
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2,
        timelineGeneration: outgoingGeneration
      )
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(5),
        duration: .seconds(100),
        position: 0.05,
        isSeekable: true
      )
      let c = player.requestJump(by: .seconds(30))

      expectNoDifference(dispatchedOffsets, [10000, 30000])
      #expect(c.initialOutcome == .pending)
    }

    @Test
    func `Native handle replacement supersedes both layers and rejects old callbacks`() async throws {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }
      let oldPointer = player.pointer
      let outgoingGeneration = player.nativeSeekMonitor._timelineGenerationForTesting
      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))

      try player.replaceNativePlayerForDrawablePlayback(target: nil)

      #expect(await a.outcome == .superseded)
      #expect(await b.outcome == .superseded)
      #expect(player.pointer != oldPointer)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.nativeSeekMonitor._timelineGenerationForTesting > outgoingGeneration)

      player.nativeSeekMonitor._noteSeekEndedForTesting(
        timelineGeneration: outgoingGeneration
      )
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2,
        timelineGeneration: outgoingGeneration
      )
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(5),
        duration: .seconds(100),
        position: 0.05,
        isSeekable: true
      )
      let c = player.requestJump(by: .seconds(30))

      expectNoDifference(dispatchedOffsets, [10000, 30000])
      #expect(c.initialOutcome == .pending)
    }

    @Test
    func `Natural terminal events rotate a tombstoned same handle lease`() async {
      let terminalEvents: [PlayerEvent] = [
        .stateChanged(.idle),
        .stateChanged(.stopping),
        .stateChanged(.stopped),
        .stateChanged(.error),
        .encounteredError
      ]

      for terminalEvent in terminalEvents {
        let player = makePlayingPlayer()
        var dispatchedOffsets: [Int64] = []
        player._nativeJumpTimeOverrideForTesting = { offset in
          dispatchedOffsets.append(offset)
          return 0
        }
        let outgoingGeneration = player.nativeSeekMonitor._timelineGenerationForTesting
        let a = player.requestJump(by: .seconds(10))
        let b = player.requestJump(by: .seconds(20))

        player.handleEvent(terminalEvent)

        #expect(await a.outcome == .superseded)
        #expect(await b.outcome == .superseded)
        #expect(player.activeNativeSeek == nil)
        #expect(player.queuedNativeSeek == nil)
        #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
        #expect(player.nativeSeekMonitor._timelineGenerationForTesting > outgoingGeneration)

        player._setStateForTesting(
          state: .playing,
          isPlaybackRequestedActive: true,
          currentTime: .seconds(5),
          duration: .seconds(100),
          position: 0.05,
          isSeekable: true
        )
        let c = player.requestJump(by: .seconds(30))
        expectNoDifference(dispatchedOffsets, [10000, 30000])
        #expect(c.initialOutcome == .pending)
      }
    }

    @Test
    func `Version four fallback does not advertise native request IDs`() {
      let player = makePlayingPlayer()
      #expect(player.nativeSeekMonitor.supportsExactSeekRequests == false)
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
