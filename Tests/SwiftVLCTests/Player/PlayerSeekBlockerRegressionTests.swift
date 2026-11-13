@testable import SwiftVLC
import CustomDump
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekBlockerRegressionTests {
    @Test
    func `Callback landing reservation beats delayed MainActor timeout exactly once`() async throws {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let captured = Mutex<NativeSeekLanding?>(nil)
      player.nativeSeekMonitor.setHandler { landing in
        captured.withLock { $0 = landing }
      }
      defer { player.configureNativeSeekMonitor() }

      let request = player.requestJump(by: .seconds(10))
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let delayedWakeUp = try #require(captured.withLock { $0 })
      #expect(player.nativeSeekMonitor._seekLandingReservationCountForTesting == 1)

      // Model the timeout task winning MainActor scheduling after VLC already
      // emitted the exact landing on its callback lane.
      player._expirePendingSeekForTesting()

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(33))
      #expect(player.nativeSeekMonitor._seekLandingReservationCountForTesting == 0)

      // The ordinary callback task eventually runs, but its wake-up no longer
      // owns the consumed fact and cannot settle or mutate a second time.
      player.nativeSeekDidLand(delayedWakeUp)
      #expect(player.currentTime == .seconds(33))
    }

    @Test
    func `Queued deadline observes emitted A landing and grants B a fresh window`() async throws {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }
      let captured = Mutex<NativeSeekLanding?>(nil)
      player.nativeSeekMonitor.setHandler { landing in
        captured.withLock { $0 = landing }
      }
      defer { player.configureNativeSeekMonitor() }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      #expect(await a.outcome == .superseded)
      #expect(player.pendingSeekSettlement?.deadlinePhase == .queued)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      _ = try #require(captured.withLock { $0 })

      // B's queue timer reaches MainActor before A's landing task. The timer
      // must reconcile the native reservation, dispatch B, and then reject its
      // own stale `.queued` phase instead of timing B out.
      player._expirePendingSeekForTesting(deadlinePhase: .queued)

      expectNoDifference(dispatchedOffsets, [10000, 20000])
      #expect(player.pendingSeekSettlement?.deadlinePhase == .dispatched)
      #expect(b.initialOutcome == .pending)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 0.4
      )
      player._expirePendingSeekForTesting()
      #expect(await b.outcome == .settled)
    }

    @Test
    func `Timeline retirement drains an undelivered seek landing reservation`() async throws {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let captured = Mutex<NativeSeekLanding?>(nil)
      player.nativeSeekMonitor.setHandler { landing in
        captured.withLock { $0 = landing }
      }
      defer { player.configureNativeSeekMonitor() }

      let request = player.requestJump(by: .seconds(10))
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let delayedWakeUp = try #require(captured.withLock { $0 })
      #expect(player.nativeSeekMonitor._seekLandingReservationCountForTesting == 1)

      player.handleEvent(.stateChanged(.stopped))

      #expect(await request.outcome == .superseded)
      #expect(player.nativeSeekMonitor._seekLandingReservationCountForTesting == 0)
      player.nativeSeekDidLand(delayedWakeUp)
      #expect(player.currentTime == .zero)
    }

    @Test
    func `Strict same direction burst preserves every offset and latest fast policy`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [(Int64, Bool)] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, fast in
        dispatchedTimes.append((milliseconds, fast))
        return 0
      }

      let a = try player.requestSeek(by: .seconds(10), fast: false)
      let b = try player.requestSeek(by: .seconds(10), fast: false)
      let c = try player.requestSeek(by: .seconds(10), fast: true)

      #expect(await a.outcome == .superseded)
      #expect(await b.outcome == .superseded)
      expectNoDifference(
        dispatchedTimes.map { "\($0.0):\($0.1)" },
        ["20000:false"]
      )

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(
        dispatchedTimes.map { "\($0.0):\($0.1)" },
        ["20000:false", "40000:true"]
      )
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 0.4
      )
      #expect(await c.outcome == .settled)
    }

    @Test
    func `Strict relative aggregate reclamps against duration at dispatch`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      _ = try player.requestSeek(by: .seconds(10))
      _ = try player.requestSeek(by: .seconds(10))
      let latest = try player.requestSeek(by: .seconds(10))
      player.duration = .seconds(35)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [20000, 35000])
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 35000,
        position: 1
      )
      #expect(await latest.outcome == .settled)
    }

    @Test
    func `Unrepresentable strict aggregate reports rejected at dispatch`() async throws {
      let player = makePlayingPlayer()
      player.currentTime = .milliseconds(LibVLCTimeMilliseconds.maximum - 10)
      player.duration = .milliseconds(Int64.max)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      var dispatchedTimes: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      let owner = player.requestJump(by: .zero)
      let earlier = try player.requestSeek(by: .milliseconds(5))
      let latest = try player.requestSeek(by: .milliseconds(10))
      #expect(await owner.outcome == .superseded)
      #expect(await earlier.outcome == .superseded)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 10000,
        position: 0.1
      )
      await drainMainActor()

      #expect(await latest.outcome == .rejected)
      #expect(dispatchedTimes.isEmpty)
    }

    @Test
    func `Native seek inputs accept exact pinned bounds and reject adjacent values`() throws {
      let maximumPlayer = makePlayingPlayer()
      maximumPlayer.duration = .milliseconds(LibVLCTimeMilliseconds.maximum)
      var absoluteDispatches: [Int64] = []
      maximumPlayer._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        absoluteDispatches.append(milliseconds)
        return 0
      }

      _ = try maximumPlayer.requestSeek(
        to: .milliseconds(LibVLCTimeMilliseconds.maximum)
      )
      expectNoDifference(absoluteDispatches, [LibVLCTimeMilliseconds.maximum])

      let outsideAbsolute = makePlayingPlayer()
      outsideAbsolute.duration = .milliseconds(LibVLCTimeMilliseconds.maximum + 1)
      outsideAbsolute._nativeSetTimeOverrideForTesting = { _, _ in
        Issue.record("Unsafe absolute seek crossed the native seam")
        return 0
      }
      #expect(throws: VLCError.self) {
        _ = try outsideAbsolute.requestSeek(
          to: .milliseconds(LibVLCTimeMilliseconds.maximum + 1)
        )
      }

      for boundary in [LibVLCTimeMilliseconds.minimum, LibVLCTimeMilliseconds.maximum] {
        let player = makePlayingPlayer()
        var offsets: [Int64] = []
        player._nativeJumpTimeOverrideForTesting = { offset in
          offsets.append(offset)
          return 0
        }
        #expect(player.requestJump(by: .milliseconds(boundary)).initialOutcome == .pending)
        expectNoDifference(offsets, [boundary])
      }

      for testCase in [
        (
          current: LibVLCTimeMilliseconds.maximum,
          offset: LibVLCTimeMilliseconds.minimum,
          expected: Int64(0)
        ),
        (
          current: Int64(0),
          offset: LibVLCTimeMilliseconds.maximum,
          expected: LibVLCTimeMilliseconds.maximum
        )
      ] {
        let player = makePlayingPlayer()
        player.currentTime = .milliseconds(testCase.current)
        player.duration = .milliseconds(LibVLCTimeMilliseconds.maximum)
        var targets: [Int64] = []
        player._nativeSetTimeOverrideForTesting = { target, _ in
          targets.append(target)
          return 0
        }
        _ = try player.requestSeek(by: .milliseconds(testCase.offset))
        expectNoDifference(targets, [testCase.expected])
      }

      for outside in [
        LibVLCTimeMilliseconds.minimum - 1,
        LibVLCTimeMilliseconds.maximum + 1
      ] {
        let player = makePlayingPlayer()
        player._nativeJumpTimeOverrideForTesting = { _ in
          Issue.record("Unsafe relative jump crossed the native seam")
          return 0
        }
        #expect(player.requestJump(by: .milliseconds(outside)).initialOutcome == .rejected)
        #expect(throws: VLCError.self) {
          _ = try player.requestSeek(by: .milliseconds(outside))
        }
      }
    }

    /// libVLC reports an unknown length as zero, and a start offset on an
    /// unknown-length input as a negative one. Stored as a known duration,
    /// either clamps every relative seek to the start of the media.
    @Test(arguments: [Duration.zero, .seconds(-20)])
    func `A non-positive native length is an unknown duration`(length: Duration) throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(20),
        duration: .seconds(60),
        position: 20.0 / 60,
        isSeekable: true
      )
      var dispatchedTargets: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTargets.append(milliseconds)
        return 0
      }

      player.handleEvent(.lengthChanged(length))
      #expect(player.duration == nil)

      _ = try player.requestSeek(by: .seconds(10))
      #expect(dispatchedTargets == [30000])
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
