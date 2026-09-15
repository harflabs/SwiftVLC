@testable import SwiftVLC
import CLibVLC
import CustomDump
import Foundation
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekSingleFlightTests {
    @Test
    func `Queued B adopts no revision until native dispatch accepts`() async throws {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      try player.seek(to: .seconds(20))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      let aRevision = player.acceptedTimelineRevision
      try player.seek(to: .seconds(40))
      let b = try #require(player.pendingSeekSettlement)

      #expect(b.timelineRevision == nil)
      #expect(player.acceptedTimelineRevision == aRevision)
      #expect(player.currentTime == .seconds(20))
      expectNoDifference(dispatchedTimes, [20000])

      // Use the real EventBridge queue and its default revision capture. The
      // raw callback belongs to A's native episode and must be retained rather
      // than overwriting either A or queued B.
      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(21)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(20))
      #expect(player.quarantinedSeekTimeline?.time == .seconds(21))

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 19000,
        position: 0.19
      )
      await drainMainActor()

      expectNoDifference(dispatchedTimes, [20000, 40000])
      #expect(player.acceptedTimelineRevision > aRevision)
      #expect(player.currentTime == .seconds(40))
      #expect(player.pendingSeekSettlement?.timelineRevision != nil)
    }

    @Test
    func `Queued rejection leaves A exact landing visible`() async throws {
      let player = makePlayingPlayer()
      var rejectDispatch = false
      player._nativeSetTimeOverrideForTesting = { _, _ in
        rejectDispatch ? -1 : 0
      }

      try player.seek(to: .seconds(20))
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      try player.seek(to: .seconds(40))
      let bResolver = try #require(player.pendingSeekSettlement?.resolver)
      rejectDispatch = true

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 18000,
        position: 0.18
      )
      await drainMainActor()

      #expect(bResolver.resolvedOutcome == .rejected)
      #expect(player.currentTime == .seconds(18))
      #expect(abs(player.position - 0.18) < 0.000_001)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
    }

    @Test
    func `Queued timeout retains intent and quarantine until A drains`() async {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let a = player.requestJump(by: .seconds(10))
      let b = player.requestJump(by: .seconds(20))
      #expect(await a.outcome == .superseded)

      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(12)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      player.eventBridge._broadcastForTesting(
        .positionChanged(0.12),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      await drainMainActor()
      #expect(player.currentTime == .seconds(10))

      player._expirePendingSeekForTesting(deadlinePhase: .queued)
      #expect(await b.outcome == .timedOut)
      #expect(player.currentTime == .seconds(10))
      #expect(abs(player.position - 0.1) < 0.000_001)
      #expect(player.activeNativeSeek != nil)
      #expect(player.queuedNativeSeek != nil)
    }

    @Test
    func `External landing is epoch tagged across main actor delay`() async {
      let player = makePlayingPlayer()

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      await drainMainActor()

      #expect(player.currentTime == .seconds(33))
      #expect(abs(player.position - 0.33) < 0.000_001)
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 1)

      let newer = makePlayingPlayer()
      newer._nativeJumpTimeOverrideForTesting = { _ in 0 }
      newer.nativeSeekMonitor._noteSeekStartedForTesting()
      newer.nativeSeekMonitor._noteSeekEndedForTesting()
      newer.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let wrapper = newer.requestJump(by: .seconds(20))
      await drainMainActor()

      #expect(wrapper.initialOutcome == .pending)
      #expect(newer.activeNativeSeek != nil)
      #expect(newer.currentTime == .seconds(10))
      newer._completePendingSeekForTesting(time: .seconds(30), position: 0.3)
      #expect(await wrapper.outcome == .settled)
    }

    @Test
    func `Overlapping external starts retain fail closed drain and quarantine raw clocks`() async {
      let player = makePlayingPlayer()

      // e1 opens the external quarantine. These raw EventBridge callbacks are
      // stamped synchronously now but cannot reach Player's MainActor consumer
      // until this test yields below.
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(33)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      player.eventBridge._broadcastForTesting(
        .positionChanged(0.33),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )

      // e2 starts before e1 has produced an end. The one untagged end and
      // delayed e1 point cannot identify either episode and must not be
      // relabeled as an e2 landing.
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      await drainMainActor()

      #expect(player.currentTime == .seconds(10))
      #expect(abs(player.position - 0.1) < 0.000_001)
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 2)
      #expect(player.latestAppliedExternalSeekEpoch == 0)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)

      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let queued = player.requestJump(by: .seconds(10))
      #expect(queued.initialOutcome == .pending)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek != nil)
    }

    @Test
    func `Tokenless no time watched point drains and publishes its position once`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        position: 0.1,
        isSeekable: true
      )

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.6
      )
      await drainMainActor()

      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.currentTime == .seconds(10))
      #expect(abs(player.position - 0.6) < 0.000_001)
      #expect(player.latestAppliedExternalSeekEpoch == 1)
      let acceptedRevision = player.acceptedTimelineRevision

      player.nativeExternalSeekDidLand(NativeExternalSeekLanding(
        timelineGeneration: player.nativeSeekMonitor.timelineGeneration,
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        externalEpoch: 1,
        timeMilliseconds: -1,
        position: 0.9
      ))

      #expect(player.currentTime == .seconds(10))
      #expect(abs(player.position - 0.6) < 0.000_001)
      #expect(player.acceptedTimelineRevision == acceptedRevision)
    }

    @Test
    func `Tokenless position only landing derives time from known duration`() async {
      let player = makePlayingPlayer()

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.6
      )
      await drainMainActor()

      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
      #expect(player.currentTime == .seconds(60))
      #expect(abs(player.position - 0.6) < 0.000_001)
    }

    @Test
    func `Delayed external epochs reject e1 after e2 and duplicate e2`() throws {
      let player = makePlayingPlayer()
      let e1 = try captureExternalLanding(
        for: player,
        timeMilliseconds: 21000,
        position: 0.21
      )
      let e2 = try captureExternalLanding(
        for: player,
        timeMilliseconds: 42000,
        position: 0.42
      )

      // e1 is already older than the monitor's current external epoch even
      // though neither MainActor delivery has been applied yet.
      player.nativeExternalSeekDidLand(e1)
      #expect(player.currentTime == .seconds(10))

      player.nativeExternalSeekDidLand(e2)
      #expect(player.currentTime == .seconds(42))
      #expect(player.latestAppliedExternalSeekEpoch == e2.externalEpoch)

      // Reversed delivery and a duplicate epoch with different payload can
      // never reacquire authority after e2 was published.
      player.nativeExternalSeekDidLand(e1)
      player.nativeExternalSeekDidLand(NativeExternalSeekLanding(
        timelineGeneration: e2.timelineGeneration,
        nativeHandleGeneration: e2.nativeHandleGeneration,
        playbackGeneration: e2.playbackGeneration,
        externalEpoch: e2.externalEpoch,
        timeMilliseconds: 99000,
        position: 0.99
      ))
      #expect(player.currentTime == .seconds(42))
      #expect(abs(player.position - 0.42) < 0.000_001)
    }

    @Test
    func `External landing rejects every attachment identity mismatch`() throws {
      let player = makePlayingPlayer()
      let landing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )

      let mismatches = [
        NativeExternalSeekLanding(
          timelineGeneration: landing.timelineGeneration &+ 1,
          nativeHandleGeneration: landing.nativeHandleGeneration,
          playbackGeneration: landing.playbackGeneration,
          externalEpoch: landing.externalEpoch,
          timeMilliseconds: landing.timeMilliseconds,
          position: landing.position
        ),
        NativeExternalSeekLanding(
          timelineGeneration: landing.timelineGeneration,
          nativeHandleGeneration: landing.nativeHandleGeneration &+ 1,
          playbackGeneration: landing.playbackGeneration,
          externalEpoch: landing.externalEpoch,
          timeMilliseconds: landing.timeMilliseconds,
          position: landing.position
        ),
        NativeExternalSeekLanding(
          timelineGeneration: landing.timelineGeneration,
          nativeHandleGeneration: landing.nativeHandleGeneration,
          playbackGeneration: landing.playbackGeneration &+ 1,
          externalEpoch: landing.externalEpoch,
          timeMilliseconds: landing.timeMilliseconds,
          position: landing.position
        )
      ]

      for mismatch in mismatches {
        player.nativeExternalSeekDidLand(mismatch)
      }
      #expect(player.currentTime == .seconds(10))
      #expect(player.latestAppliedExternalSeekEpoch == 0)

      player.nativeExternalSeekDidLand(landing)
      #expect(player.currentTime == .seconds(33))
    }

    @Test
    func `Outgoing external landing is rejected after timeline reset`() throws {
      let player = makePlayingPlayer()
      let outgoing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )

      player.resetMediaDerivedState()
      player.nativeExternalSeekDidLand(outgoing)

      #expect(player.currentTime == .zero)
      #expect(player.position == 0)
      #expect(player.latestAppliedExternalSeekEpoch == 0)
    }

    @Test
    func `Outgoing external landing is rejected after load`() throws {
      let player = makePlayingPlayer()
      let outgoing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )

      try player.load(Media(url: TestMedia.twosecURL))
      player.nativeExternalSeekDidLand(outgoing)

      #expect(player.currentTime == .zero)
      #expect(player.position == 0)
      #expect(player.latestAppliedExternalSeekEpoch == 0)
    }

    @Test
    func `Outgoing external landing is rejected after cold replay`() throws {
      let player = makePlayingPlayer()
      let outgoing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )
      player._setStateForTesting(state: .stopped, isPlaybackRequestedActive: false)
      player._nativePlaybackStateOverrideForTesting = .stopped
      player.nativePlayerHasStartedPlayback = true
      player._nativePlayOverrideForTesting = { 0 }

      try player.play()
      player.nativeExternalSeekDidLand(outgoing)

      #expect(player.sessionGeneration > outgoing.playbackGeneration)
      #expect(player.currentTime == .seconds(10))
      #expect(player.latestAppliedExternalSeekEpoch == 0)
    }

    @Test
    func `Outgoing external landing is rejected after native handle replacement`() throws {
      let player = makePlayingPlayer()
      let outgoing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )

      try player.replaceNativePlayerForDrawablePlayback(target: nil)
      player.nativeExternalSeekDidLand(outgoing)

      #expect(
        player.eventBridge.currentNativeHandleGeneration
          > outgoing.nativeHandleGeneration
      )
      #expect(player.currentTime == .seconds(10))
      #expect(player.latestAppliedExternalSeekEpoch == 0)
    }

    @Test
    func `External landing cannot overwrite a newer settled wrapper dispatch`() async throws {
      let player = makePlayingPlayer()
      let outgoing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let wrapper = player.requestJump(by: .seconds(20))
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 30000,
        position: 0.3
      )
      #expect(await wrapper.outcome == .settled)
      player.nativeExternalSeekDidLand(outgoing)

      #expect(player.currentTime == .seconds(30))
      #expect(abs(player.position - 0.3) < 0.000_001)
    }

    @Test
    func `Later raw clock wins when external landing delivery is delayed`() async throws {
      try await verifyExternalLandingOrderedBeforeLaterRawClock(
        deliverLandingFirst: false
      )
    }

    @Test
    func `Later raw clock wins when external landing commits first`() async throws {
      try await verifyExternalLandingOrderedBeforeLaterRawClock(
        deliverLandingFirst: true
      )
    }

    @Test
    func `Later exact frame wins when external landing delivery is delayed`() async throws {
      try await verifyExternalLandingOrderedBeforeLaterFrame(
        deliverLandingFirst: false
      )
    }

    @Test
    func `Later exact frame wins when external landing commits first`() async throws {
      try await verifyExternalLandingOrderedBeforeLaterFrame(
        deliverLandingFirst: true
      )
    }

    @Test
    func `Later raw clock survives wrapper quarantine when landing is delayed`() async throws {
      try await verifyWrapperLandingOrderedBeforeLaterRawClock(
        deliverLandingFirst: false
      )
    }

    @Test
    func `Later raw clock wins when wrapper landing commits first`() async throws {
      try await verifyWrapperLandingOrderedBeforeLaterRawClock(
        deliverLandingFirst: true
      )
    }

    @Test
    func `Cold replay establishes a fresh playback generation`() throws {
      for terminalState in [PlayerState.idle, .stopped, .error] {
        let player = Player(instance: TestInstance.makeAudioOnly())
        player._setStateForTesting(
          state: terminalState,
          isPlaybackRequestedActive: false
        )
        player.nativePlayerHasStartedPlayback = true
        player._nativePlayOverrideForTesting = { 0 }
        let before = player.sessionGeneration

        try player.play()

        #expect(player.sessionGeneration > before)
        #expect(player.eventBridge.currentPlaybackGeneration == player.sessionGeneration)
      }

      let initial = Player(instance: TestInstance.makeAudioOnly())
      initial._setStateForTesting(state: .idle, isPlaybackRequestedActive: false)
      initial._nativePlayOverrideForTesting = { 0 }
      let initialGeneration = initial.sessionGeneration
      try initial.play()
      #expect(initial.sessionGeneration == initialGeneration)

      let paused = makePlayingPlayer()
      paused._setStateForTesting(state: .paused, isPlaybackRequestedActive: false)
      paused.nativePlayerHasStartedPlayback = true
      paused._nativePlayOverrideForTesting = { 0 }
      let pausedGeneration = paused.sessionGeneration
      try paused.play()
      #expect(paused.sessionGeneration == pausedGeneration)
    }

    @Test
    func `Retiring terminal sourced before cold replay cannot clear successor drain`() async throws {
      let player = makePlayingPlayer()
      player._setStateForTesting(state: .stopped, isPlaybackRequestedActive: false)
      player.nativePlayerHasStartedPlayback = true
      player._nativePlayOverrideForTesting = { 0 }
      let retiringGeneration = player.sessionGeneration
      try player.play()
      let successorGeneration = player.sessionGeneration
      #expect(successorGeneration > retiringGeneration)

      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let request = player.requestJump(by: .seconds(10))
      let monitorGeneration = player.nativeSeekMonitor._timelineGenerationForTesting

      player.eventBridge._broadcastForTesting(
        .encounteredError,
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: retiringGeneration
      )
      await drainMainActor()

      #expect(request.initialOutcome == .pending)
      #expect(player.activeNativeSeek != nil)
      #expect(player.nativeSeekMonitor._timelineGenerationForTesting == monitorGeneration)
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)

      player.eventBridge._broadcastForTesting(
        .stateChanged(.stopped),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: successorGeneration,
        emittedTimelineRevision: 0
      )
      await drainMainActor()
      #expect(await request.outcome == .superseded)
      #expect(!player.nativeSeekMonitor.hasSeekDrainPending)
    }

    @Test
    func `Terminal callbacks retain outgoing ownership from callback entry`() async throws {
      for terminal in CallbackEntryTerminal.allCases {
        let player = Player(instance: TestInstance.makeAudioOnly())
        try player.load(Media(url: TestMedia.twosecURL))
        player._setStateForTesting(
          state: .playing,
          isPlaybackRequestedActive: true,
          currentTime: .seconds(1),
          duration: .seconds(2),
          position: 0.5,
          isSeekable: true
        )
        let outgoingGeneration = player.sessionGeneration
        let bridge = player.eventBridge
        let mediaAddress = player.currentMedia.map { UInt(bitPattern: $0.pointer) }
        let sourcedStream = bridge.makeSourcedStream(policy: .unbounded)
        let sourcedTerminal = Task.detached { () -> SourcedPlayerEvent? in
          for await sourced in sourcedStream where terminal.matches(sourced.event) {
            return sourced
          }
          return nil
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        bridge._setNativeEventCallbackEntryHookForTesting {
          entered.signal()
          _ = release.wait(timeout: .now() + 5)
        }

        let callback = Task.detached {
          var event = libvlc_event_t()
          switch terminal {
          case .stopped:
            event.type = Int32(libvlc_MediaPlayerStopped.rawValue)
          case .encounteredError:
            event.type = Int32(libvlc_MediaPlayerEncounteredError.rawValue)
            event.u.media_player_encountered_error.failure = libvlc_playback_failure_decoder
          case .mediaStopping:
            event.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
            event.u.media_player_media_stopping.media = mediaAddress.flatMap {
              OpaquePointer(bitPattern: $0)
            }
            event.u.media_player_media_stopping.reason = libvlc_stopping_reason_error
          }
          bridge._emitNativeEventForTesting(event)
        }
        let reachedEntry = await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
              returning: entered.wait(timeout: .now() + 5) == .success
            )
          }
        }
        try #require(reachedEntry)

        // The terminal callback already owns the outgoing generation, but is
        // paused before mapping. Cold replay advances both playback and seek
        // attachment identity while the callback is still in flight.
        player._setStateForTesting(
          state: .stopped,
          isPlaybackRequestedActive: false
        )
        player._nativePlaybackStateOverrideForTesting = .stopped
        player.nativePlayerHasStartedPlayback = true
        player._nativePlayOverrideForTesting = { 0 }
        try player.play()
        #expect(player.sessionGeneration > outgoingGeneration)

        player._setStateForTesting(
          state: .playing,
          isPlaybackRequestedActive: true,
          currentTime: .seconds(1),
          duration: .seconds(2),
          position: 0.5,
          isSeekable: true
        )
        player._nativeJumpTimeOverrideForTesting = { _ in 0 }
        let successor = player.requestJump(by: .milliseconds(250))
        let successorMonitorGeneration = player.nativeSeekMonitor.timelineGeneration
        #expect(successor.initialOutcome == .pending)

        release.signal()
        await callback.value
        bridge._setNativeEventCallbackEntryHookForTesting(nil)
        let sourced = try #require(await sourcedTerminal.value)
        await drainMainActor()

        #expect(sourced.playbackGeneration == outgoingGeneration)
        #expect(successor.initialOutcome == .pending)
        #expect(player.activeNativeSeek != nil)
        #expect(player.nativeSeekMonitor.hasSeekDrainPending)
        #expect(player.nativeSeekMonitor.timelineGeneration == successorMonitorGeneration)

        player.nativeSeekMonitor._noteSeekEndedForTesting()
        player.nativeSeekMonitor._noteTimeUpdatedForTesting(
          timeMilliseconds: 1250,
          position: 0.625
        )
        #expect(await successor.outcome == .settled)
      }
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

    private enum CallbackEntryTerminal: CaseIterable, Sendable {
      case stopped
      case encounteredError
      case mediaStopping

      func matches(_ event: PlayerEvent) -> Bool {
        switch (self, event) {
        case (.stopped, .stateChanged(.stopped)),
             (.encounteredError, .encounteredError),
             (.mediaStopping, .mediaStopping):
          true
        default:
          false
        }
      }
    }

    /// Captures the exact callback-thread payload before handing it to Player,
    /// modeling an external landing queued across a later causal boundary.
    private func captureExternalLanding(
      for player: Player,
      timeMilliseconds: Int64,
      position: Double
    )
      throws -> NativeExternalSeekLanding {
      let captured = Mutex<NativeExternalSeekLanding?>(nil)
      player.nativeSeekMonitor.setSeekStartedHandler { _ in }
      player.nativeSeekMonitor.setExternalSeekLandingHandler { landing in
        captured.withLock { $0 = landing }
      }
      defer { player.configureNativeSeekMonitor() }

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: timeMilliseconds,
        position: position
      )
      return try #require(captured.withLock { $0 })
    }

    private func verifyExternalLandingOrderedBeforeLaterRawClock(
      deliverLandingFirst: Bool
    )
      async throws {
      let player = makePlayingPlayer()
      let landing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )

      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(34)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )
      if deliverLandingFirst {
        player.nativeExternalSeekDidLand(landing)
      } else {
        await drainMainActor()
        #expect(player.currentTime == .seconds(34))
        player.nativeExternalSeekDidLand(landing)
      }
      await drainMainActor()

      #expect(player.currentTime == .seconds(34))
      #expect(
        player.acceptedNativeTimelineEmissionSequence
          > landing.emissionSequence
      )
    }

    private func verifyExternalLandingOrderedBeforeLaterFrame(
      deliverLandingFirst: Bool
    )
      async throws {
      let player = makePlayingPlayer()
      player._setStateForTesting(state: .paused, nativeState: .paused)
      let landing = try captureExternalLanding(
        for: player,
        timeMilliseconds: 33000,
        position: 0.33
      )
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }

      player.nextFrame()
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 34_000_000,
        position: 0.34
      )
      if deliverLandingFirst {
        player.nativeExternalSeekDidLand(landing)
      } else {
        await drainMainActor()
        #expect(player.currentTime == .seconds(34))
        player.nativeExternalSeekDidLand(landing)
      }
      await drainMainActor()

      #expect(player.currentTime == .seconds(34))
      #expect(abs(player.position - 0.34) < 0.000_001)
      #expect(
        player.acceptedNativeTimelineEmissionSequence
          > landing.emissionSequence
      )
    }

    private func verifyWrapperLandingOrderedBeforeLaterRawClock(
      deliverLandingFirst: Bool
    )
      async throws {
      let player = makePlayingPlayer()
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let captured = Mutex<NativeSeekLanding?>(nil)
      player.nativeSeekMonitor.setHandler { landing in
        captured.withLock { $0 = landing }
      }
      // Hold both landing wake-ups. The monitor also emits a drain-available
      // notification for this same callback fact; production now reconciles
      // the reserved landing from either task, so delaying only one no longer
      // models executor inversion.
      player.nativeSeekMonitor.setSeekDrainAvailabilityHandler {}
      defer { player.configureNativeSeekMonitor() }

      let request = player.requestJump(by: .seconds(10))
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let landing = try #require(captured.withLock { $0 })
      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(34)),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration
      )

      if deliverLandingFirst {
        player.nativeSeekDidLand(landing)
      } else {
        await drainMainActor()
        #expect(player.quarantinedSeekTimeline?.time == .seconds(34))
        player.nativeSeekDidLand(landing)
      }
      await drainMainActor()

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(34))
      #expect(
        player.acceptedNativeTimelineEmissionSequence
          > landing.emissionSequence
      )
    }

    private func drainMainActor() async {
      for _ in 0..<30 {
        await Task.yield()
      }
    }
  }
}
