@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekRequestLifecycleTests {
    @Test
    func `Absolute time request exposes authoritative settlement`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        currentTime: .seconds(5),
        duration: .seconds(100),
        position: 0.05,
        isSeekable: true
      )
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeSetTimeOverrideForTesting = { milliseconds, fast in
        #expect(milliseconds == 25000)
        #expect(!fast)
        return 0
      }

      let request = try player.requestSeek(to: .seconds(25))

      #expect(request.initialOutcome == .pending)
      player._completePendingSeekForTesting(time: .seconds(25), position: 0.25)
      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(25))
      #expect(player.playbackPosition == PlaybackPosition(0.25))
    }

    @Test
    func `Strict fractional request freezes one absolute target`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        currentTime: .seconds(5),
        duration: .seconds(80),
        position: 0.0625,
        isSeekable: true
      )
      player._nativePlaybackStateOverrideForTesting = .paused
      var dispatchedMilliseconds: Int64?
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedMilliseconds = milliseconds
        return 0
      }

      let request = try player.requestSeek(to: PlaybackPosition(0.25), fast: true)

      #expect(dispatchedMilliseconds == 20000)
      player._completePendingSeekForTesting(time: .seconds(20), position: 0.25)
      #expect(await request.outcome == .settled)
    }

    @Test
    func `Lenient fractional request reports rejection and eventual landing`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeSetPositionOverrideForTesting = { position, fast in
        #expect(position == 0.4)
        #expect(fast)
        return 0
      }

      let request = player.requestSeek(toPosition: PlaybackPosition(0.4), fast: true)

      #expect(request.initialOutcome == .pending)
      player._completePendingSeekForTesting(time: .seconds(40), position: 0.4)
      #expect(await request.outcome == .settled)

      player._setStateForTesting(state: .stopped, isPlaybackRequestedActive: false)
      let rejected = player.requestSeek(toPosition: PlaybackPosition(0.6))
      #expect(rejected.initialOutcome == .rejected)
      #expect(await rejected.outcome == .rejected)
    }

    @Test
    func `Strict request validation fails before native dispatch`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var dispatchCount = 0
      player._nativeSetTimeOverrideForTesting = { _, _ in
        dispatchCount += 1
        return 0
      }

      #expect(throws: VLCError.self) {
        try player.requestSeek(to: .seconds(1))
      }
      player._setStateForTesting(
        state: .paused,
        duration: .seconds(10),
        isSeekable: true
      )
      #expect(throws: VLCError.self) {
        try player.requestSeek(to: .seconds(11))
      }
      #expect(dispatchCount == 0)
    }

    /// The DEBUG completion helper rejects stale internal delivery tokens.
    /// This does not claim that libVLC 4 supplies a native request ID; the
    /// production watcher relies on sole serialized episode attribution.
    @Test
    func `Internal completion helper ignores a different delivery token`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      let token = try #require(player.pendingSeekSettlement?.nativeSeekToken)

      player._completePendingSeekForTesting(time: .seconds(10), token: token &+ 1)
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._completePendingSeekForTesting(time: .seconds(10), token: token)
      #expect(await request.outcome == .settled)
    }

    /// Rapid alternating skip controls must give every displaced request an
    /// explicit result while leaving only the newest one able to settle. The
    /// second command does not enter VLC until the first episode drains.
    @Test
    func `A newer jump supersedes the previous request`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .buffering,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(50),
        duration: .seconds(100)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let first = player.requestJump(by: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      let second = player.requestJump(by: .seconds(-20))
      let secondRevision = player.acceptedTimelineRevision

      #expect(await first.outcome == .superseded)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(60)),
        timelineRevision: firstRevision
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(40)),
        timelineRevision: secondRevision
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 60000,
        position: 0.6
      )
      for _ in 0..<50 where player.activeNativeSeek?.command.nativeSeekToken
        != player.pendingSeekSettlement?.nativeSeekToken {
        await Task.yield()
      }
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 0.4
      )
      #expect(await second.outcome == .settled)
      #expect(player.currentTime == .seconds(40))
    }

    /// A command accepted behind an active seek cannot expose its eventual
    /// defensive native rejection synchronously. Its request starts pending,
    /// supersedes the older public intent, and later resolves rejected when it
    /// reaches the dispatch boundary.
    @Test
    func `A queued jump reports a later native rejection truthfully`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let first = player.requestJump(by: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      player._nativeJumpTimeOverrideForTesting = { _ in -1 }
      let rejected = player.requestJump(by: .seconds(20))

      #expect(rejected.initialOutcome == .pending)
      #expect(await first.outcome == .superseded)
      #expect(player.acceptedTimelineRevision == firstRevision)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 10000,
        position: -.infinity
      )
      #expect(await rejected.outcome == .rejected)
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.activeNativeSeek == nil)
    }

    /// A queued position seek reports local acceptance because its native call
    /// happens later. If that deferred call fails, the lane becomes available
    /// for a subsequent position command without lending it the failed token.
    @Test
    func `A queued position seek releases the lane after deferred rejection`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let first = player.requestJump(by: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      player._nativeSetPositionOverrideForTesting = { _, _ in -1 }

      #expect(player.seek(toPosition: PlaybackPosition(0.4)))
      #expect(await first.outcome == .superseded)
      #expect(player.acceptedTimelineRevision == firstRevision)
      #expect(player.position == 0)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 10000,
        position: 0.1
      )
      for _ in 0..<20 where player.pendingSeekSettlement != nil {
        await Task.yield()
      }
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.activeNativeSeek == nil)

      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      #expect(player.seek(toPosition: PlaybackPosition(0.5)))
      #expect(player.acceptedTimelineRevision > firstRevision)
      #expect(player.position == 0.5)
    }

    /// The pinned libVLC 4 implementation currently returns zero from every
    /// seek entry point, so landing evidence—not this result—is authoritative.
    /// Keep the defensive nonzero branch transactional for custom or future
    /// builds: it must not publish an estimate or consume timeline authority.
    @Test
    func `A native dispatch failure leaves the timeline unchanged`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(12),
        duration: .seconds(100)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in -1 }
      let acceptedRevision = player.acceptedTimelineRevision

      let request = player.requestJump(by: .seconds(30))

      #expect(request.initialOutcome == .rejected)
      #expect(await request.outcome == .rejected)
      #expect(player.acceptedTimelineRevision == acceptedRevision)
      #expect(player.currentTime == .seconds(12))
    }

    /// An accepted command that never produces native completion cannot leave an
    /// AVKit completion suspended indefinitely.
    @Test
    func `An accepted jump has a bounded timeout result`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(12),
        duration: .seconds(100),
        position: 0.12
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(30))
      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(14)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      player.eventBridge._broadcastForTesting(
        .positionChanged(0.14),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(12))
      player._expirePendingSeekForTesting()

      #expect(await request.outcome == .timedOut)
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(14))
      #expect(abs(player.position - 0.14) < 0.000_001)
    }

    /// A sample stamped after dispatch but before the engine reached the
    /// target is the pre-seek position. Replaying it when observation expires
    /// snapped a stalled seek's published time back until its late landing.
    @Test
    func `A timed out seek keeps its published target until the native episode drains`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100),
        position: 0.1,
        isSeekable: true
      )
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }

      let request = try player.requestSeek(to: .seconds(40))
      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(11)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(40))
      player._expirePendingSeekForTesting()

      #expect(await request.outcome == .timedOut)
      #expect(player.currentTime == .seconds(40))
      #expect(player.activeNativeSeek?.isTombstoned == true)

      // The late landing still corrects the mirror and frees the lane.
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 39000,
        position: 0.39
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(39))
      #expect(player.activeNativeSeek == nil)
      #expect(player.quarantinedSeekTimeline == nil)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(await request.outcome == .timedOut)
    }

    /// Media replacement establishes a new generation and makes the outgoing
    /// request explicitly superseded, even if its old event arrives later.
    @Test
    func `A media reset supersedes a pending jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      player.resetMediaDerivedState()

      #expect(await request.outcome == .superseded)
    }

    /// Renderer recast establishes a successor playback generation without a
    /// media reset. That generation boundary must terminate the outgoing seek
    /// immediately rather than leaving it to time out.
    @Test
    func `A playback generation change supersedes a pending jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      let monitorGeneration = player.nativeSeekMonitor._timelineGenerationForTesting
      player.sessionGeneration = player.eventBridge.synchronizePlaybackGeneration(
        player.sessionGeneration &+ 1,
        media: player.currentMedia?.pointer
      )

      #expect(await request.outcome == .superseded)
      #expect(player.nativeSeekMonitor._timelineGenerationForTesting > monitorGeneration)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

      let next = player.requestJump(by: .seconds(20))
      #expect(next.initialOutcome == .pending)
      player._completePendingSeekForTesting(time: .seconds(20), position: 0.2)
      #expect(await next.outcome == .settled)
    }

    /// An explicit stop is authoritative immediately; completion does not
    /// wait for libVLC's asynchronous stopped event before discharging a skip.
    @Test
    func `Stopping supersedes a pending jump synchronously`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      player._nativePlaybackStateOverrideForTesting = .idle
      player.stop()

      #expect(await request.outcome == .superseded)
    }

    /// Cancelling an observer does not cancel or misclassify the shared seek.
    @Test
    func `Cancelling one waiter does not cancel the seek`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let request = player.requestJump(by: .seconds(10))
      let waiter = Task { await request.outcome }

      waiter.cancel()
      await Task.yield()
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._completePendingSeekForTesting(time: .seconds(10))

      #expect(await waiter.value == .settled)
    }

    /// Relative jumping changes only the timeline; it does not synthesize the
    /// pause/mute transport sequence that previously left PiP playback stuck.
    @Test
    func `A jump preserves pause intent and mute state`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: false,
        currentTime: .seconds(5),
        duration: .seconds(100)
      )
      player.isMuted = true
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(5))
      player._completePendingSeekForTesting(time: .seconds(10), position: 0.1)

      #expect(await request.outcome == .settled)
      #expect(player.state == .paused)
      #expect(player.isPlaybackRequestedActive == false)
      #expect(player.isMuted)
    }

    private func drainMainActor() async {
      for _ in 0..<30 {
        await Task.yield()
      }
    }
  }
}
