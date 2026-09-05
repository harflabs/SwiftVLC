@testable import SwiftVLC
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct MediaListPlayerExtendedTests {
    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Play specific item at index from list`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.testMP4URL))
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      // Play the second item directly by index
      try listPlayer.play(at: 1)
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Mode switching during playback`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      #expect(listPlayer.playbackMode == .default)
      listPlayer.play()
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      // Switch to loop mode while playing
      listPlayer.playbackMode = .loop
      #expect(listPlayer.playbackMode == .loop)
      // Switch to repeat mode while playing
      listPlayer.playbackMode = .repeat
      #expect(listPlayer.playbackMode == .repeat)
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Toggle pause during playback`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      // Toggle pause — should pause
      listPlayer.togglePause()
      try await Task.sleep(for: .milliseconds(150))
      // Toggle pause again — should resume
      listPlayer.togglePause()
      try await Task.sleep(for: .milliseconds(150))
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Replace mediaList while playing`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      let list1 = MediaList()
      try list1.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list1
      listPlayer.play()
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      // Replace the list while playing
      let list2 = MediaList()
      try list2.append(Media(url: TestMedia.testMP4URL))
      listPlayer.mediaList = list2
      #expect(listPlayer.mediaList != nil)
      listPlayer.stop()
    }

    @Test
    func `Replace mediaPlayer while configured`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player1 = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player1
      #expect(listPlayer.mediaPlayer != nil)
      // Replace with a different player
      let player2 = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player2
      #expect(listPlayer.mediaPlayer != nil)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Play from beginning after stop`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      // First play cycle
      listPlayer.play()
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      listPlayer.stop()
      try #require(await poll(until: { !listPlayer.isPlaying }), "Waiting for: !listPlayer.isPlaying")
      // Second play cycle — should start from beginning
      listPlayer.play()
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      listPlayer.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `State reflects paused during pause`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()
      try #require(await poll(until: { listPlayer.isPlaying }), "Waiting for: listPlayer.isPlaying")
      listPlayer.pause()
      let immediateDiagnostic =
        "after pause: list=\(listPlayer.state), player=\(player.state), native=\(player.nativePlaybackState), "
          + "pausable=\(player.isPausable), deferred=\(String(describing: player.deferredPauseCommand)), "
          + "transition=\(String(describing: player.pauseTransition)); "
      let reachedPaused = try await poll(until: { listPlayer.state == .paused })
      let diagnostic =
        immediateDiagnostic
          + "at timeout: list=\(listPlayer.state), player=\(player.state), native=\(player.nativePlaybackState), "
          + "pausable=\(player.isPausable), deferred=\(String(describing: player.deferredPauseCommand)), "
          + "transition=\(String(describing: player.pauseTransition))"
      #expect(
        reachedPaused,
        Comment(rawValue: diagnostic)
      )
      listPlayer.stop()
    }

    @Test
    func `Pause while cached playback is opening is deferred`() {
      let instance = TestInstance.shared
      let player = Player(instance: instance)
      player._setStateForTesting(state: .opening, isPlaybackRequestedActive: true)

      player.pause()

      #expect(player.deferredPauseCommand == .pause)
      #expect(player.isPlaybackRequestedActive == false)
    }

    @Test
    func `Resume cancels an attached player's deferred pause`() {
      let instance = TestInstance.shared
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      listPlayer.mediaPlayer = player
      player.setDeferredPauseCommand(.pause, playbackGeneration: player.sessionGeneration)
      player.publishPlaybackIntent(false)

      listPlayer.resume()

      #expect(player.deferredPauseCommand == nil)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `List play and stop publish explicit transport intent only for a playable list`() throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      player.setPlaybackControlIntent(.pause)

      listPlayer.play()

      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!player.nativePlayerHasStartedPlayback)

      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()

      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.nativePlayerHasStartedPlayback)

      player.setPauseTransition(
        .pausing,
        playbackGeneration: player.eventBridge.currentPlaybackGeneration
      )
      player.setDeferredPauseCommand(
        .pause,
        playbackGeneration: player.eventBridge.currentPlaybackGeneration
      )
      player.setPlaybackControlIntent(.pause)
      listPlayer.stop()

      #expect(player.playbackControlIntent == nil)
      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == nil)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.nativePlayerHasStartedPlayback)
    }

    @Test
    func `Idle pause rejection preserves the previous transport intent`() {
      let player = Player(instance: TestInstance.shared)
      player._nativePlaybackStateOverrideForTesting = .idle
      player.setPlaybackControlIntent(.resume)

      player.pause()

      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Idle resume rejection preserves the previous transport intent`() {
      let player = Player(instance: TestInstance.shared)
      player._nativePlaybackStateOverrideForTesting = .idle
      player.setPlaybackControlIntent(.pause)

      player.resume()

      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Pause rollback cannot erase intent after callback-lane advancement`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      player._nativePlaybackStateOverrideForTesting = .idle
      player.setPlaybackControlIntent(.resume)
      player._pauseProbeHookForTesting = { stage in
        guard stage == .pauseRollback else { return }
        _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)
      }

      player.pause()

      #expect(player.playbackControlIntent == .pause)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == 1)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Resume rollback cannot erase intent after callback-lane advancement`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      player._nativePlaybackStateOverrideForTesting = .idle
      player.setPlaybackControlIntent(.pause)
      player._pauseProbeHookForTesting = { stage in
        guard stage == .resumeRollback else { return }
        _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)
      }

      player.resume()

      #expect(player.playbackControlIntent == .resume)
      #expect(player.deferredPauseCommand == .resume)
      #expect(player.deferredPauseCommandPlaybackGeneration == 1)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Accepted list play supersedes a deferred pause while opening`() throws {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      player._nativePlaybackStateOverrideForTesting = .opening
      player.setDeferredPauseCommand(
        .pause,
        playbackGeneration: player.eventBridge.currentPlaybackGeneration
      )
      player.setPlaybackControlIntent(.pause)

      listPlayer.play()

      #expect(player.playbackControlIntent == .resume)
      #expect(player.deferredPauseCommand == .resume)
      #expect(
        player.deferredPauseCommandPlaybackGeneration
          == player.eventBridge.currentPlaybackGeneration
      )
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Pause cancellation carries resume rather than stale pause into adoption`() {
      let player = Player(instance: TestInstance.shared)
      player._nativePlaybackStateOverrideForTesting = .playing
      player.setDeferredPauseCommand(.pause, playbackGeneration: 0)
      player.setPlaybackControlIntent(.pause)

      player.cancelPendingPause()
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)
      player.handleEvent(.mediaChanged, sourcePlaybackGeneration: 1)

      #expect(player.playbackControlIntent == .resume)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Media adoption preserves a pause accepted for its native generation`() {
      let player = Player(instance: TestInstance.shared)
      let adoptedGeneration: UInt64 = 1
      player.sessionGeneration = adoptedGeneration
      _ = player.eventBridge.synchronizePlaybackGeneration(adoptedGeneration, media: nil)
      player.deferredPauseCommand = .pause

      player.resetMediaDerivedState()

      #expect(player.deferredPauseCommand == .pause)
    }

    @Test
    func `Playlist pause decisions use successor native state while adoption is queued`() {
      for staleState in [PlayerState.idle, .stopped, .playing] {
        #expect(
          Player.pauseDecisionState(
            cached: staleState,
            native: .opening,
            hasAttachedMediaListPlayer: true,
            callbackLaneIsAhead: true
          ) == .opening
        )
      }
      #expect(
        Player.pauseDecisionState(
          cached: .playing,
          native: .idle,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: true
        ) == .opening
      )
      #expect(
        Player.pauseDecisionState(
          cached: .stopped,
          native: .idle,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: false,
          mediaListPlaybackActive: true
        ) == .opening
      )
      #expect(
        Player.pauseDecisionState(
          cached: .stopped,
          native: .stopped,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: false,
          mediaListPlaybackActive: true
        ) == .opening
      )
      #expect(
        Player.pauseDecisionState(
          cached: .stopped,
          native: .idle,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: false,
          mediaListPlaybackActive: false
        ) == .idle
      )
      #expect(
        Player.pauseDecisionState(
          cached: .stopped,
          native: .opening,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: false
        ) == .opening
      )
      #expect(
        Player.pauseDecisionState(
          cached: .stopped,
          native: .paused,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: false
        ) == .paused
      )
      #expect(
        Player.pauseDecisionState(
          cached: .stopped,
          native: .opening,
          hasAttachedMediaListPlayer: false,
          callbackLaneIsAhead: true
        ) == .stopped
      )
      #expect(
        Player.pauseDecisionState(
          cached: .playing,
          native: .idle,
          hasAttachedMediaListPlayer: true,
          callbackLaneIsAhead: false
        ) == .playing
      )
    }

    @Test
    func `Fresh pause control follows a generation that advances during native probes`() {
      #expect(
        Player.revalidatedPauseGeneration(
          captured: 1,
          current: 2,
          followsCurrentGeneration: true
        ) == 2
      )
      #expect(
        Player.revalidatedPauseGeneration(
          captured: 1,
          current: 2,
          followsCurrentGeneration: false
        ) == nil
      )
    }

    @Test
    func `A stale generation-bound fresh pause restores the preceding intent`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player.setPlaybackControlIntent(.resume)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)

      #expect(!player.issuePause(playbackGeneration: 0))
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `Restoring a preceding pause keeps published intent inactive`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: false)
      player.setPlaybackControlIntent(.pause)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)

      #expect(!player.issuePause(playbackGeneration: 0))
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Scoped PiP cancellation preserves a newer pause on the same generation`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let generation: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      player.setDeferredPauseCommand(.pause, playbackGeneration: generation)
      player.setPlaybackControlIntent(.pause)
      let piPRevision = player.playbackControlIntentRevision
      player.setPlaybackControlIntent(.pause)

      player.cancelPendingPause(
        playbackGeneration: generation,
        playbackControlRevision: piPRevision
      )

      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == generation)
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `A bound pause that reaches a terminal state restores the preceding intent`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let generation: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      player._setStateForTesting(state: .stopped, isPlaybackRequestedActive: false)
      player.setPlaybackControlIntent(.resume)

      #expect(!player.issuePause(playbackGeneration: generation))
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `A generation-bound fresh pause restores intent after a capability probe race`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let capturedGeneration: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(capturedGeneration, media: nil)
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player.setPlaybackControlIntent(.resume)
      player._pauseProbeHookForTesting = { stage in
        guard stage == .capability else { return }
        player._pauseProbeHookForTesting = nil
        _ = player.eventBridge.synchronizePlaybackGeneration(
          capturedGeneration + 1,
          media: nil
        )
      }

      #expect(!player.issuePause(playbackGeneration: capturedGeneration))
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `A current-following pause carries its command across a native pause race`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let capturedGeneration: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(capturedGeneration, media: nil)
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player.setDeferredPauseCommand(.pause, playbackGeneration: capturedGeneration)
      player._pauseProbeHookForTesting = { stage in
        guard stage == .nativePause else { return }
        player._pauseProbeHookForTesting = nil
        _ = player.eventBridge.synchronizePlaybackGeneration(
          capturedGeneration + 1,
          media: nil
        )
      }

      #expect(player.issuePause())
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == capturedGeneration + 1)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `A bound pause retry carries a persistent pause intent to the successor`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let capturedGeneration: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(capturedGeneration, media: nil)
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: false)
      player.setPlaybackControlIntent(.pause)
      player._pauseProbeHookForTesting = { stage in
        guard stage == .nativePause else { return }
        player._pauseProbeHookForTesting = nil
        _ = player.eventBridge.synchronizePlaybackGeneration(
          capturedGeneration + 1,
          media: nil
        )
      }

      #expect(
        !player.issuePause(
          playbackGeneration: capturedGeneration,
          recordsPlaybackControlIntent: false
        )
      )
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == capturedGeneration + 1)
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Fresh pause retains the newest generation after repeated state probe races`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      var generation: UInt64 = 0
      player._pauseProbeHookForTesting = { stage in
        guard stage == .state else { return }
        generation &+= 1
        _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      }

      #expect(!player.issuePause())
      #expect(generation == 3)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == generation)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Fresh pause retains the newest generation after repeated capability probe races`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        state: .playing,
        duration: .seconds(120),
        isSeekable: true,
        isPausable: true
      )
      let capabilityBeforeRace = player.capabilitySnapshot.withLock { $0 }
      var generation: UInt64 = 0
      player._pauseProbeHookForTesting = { stage in
        guard stage == .capability else { return }
        generation &+= 1
        _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      }

      #expect(!player.issuePause())
      #expect(generation == 3)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == generation)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.capabilitySnapshot.withLock { $0 } == capabilityBeforeRace)
    }

    @Test
    func `Fresh resume retains the newest generation after repeated state probe races`() {
      let player = Player(instance: TestInstance.shared)
      var generation: UInt64 = 0
      player._pauseProbeHookForTesting = { stage in
        guard stage == .resumeState else { return }
        generation &+= 1
        _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      }

      #expect(player.issueResume())
      #expect(generation == 3)
      #expect(player.deferredPauseCommand == .resume)
      #expect(player.deferredPauseCommandPlaybackGeneration == generation)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `A generation-bound fresh PiP pause replaces stale list resume intent`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let generation: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player.setPlaybackControlIntent(.resume)

      #expect(player.issuePause(playbackGeneration: generation))
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)

      player.handleEvent(.mediaChanged, sourcePlaybackGeneration: generation)

      #expect(
        player.playbackControlIntent == .pause,
        "media adoption resurrected the list resume that preceded the PiP pause"
      )
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `A generation-bound pause repairs advancement during the native command`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let capturedGeneration: UInt64 = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(capturedGeneration, media: nil)
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player.setPlaybackControlIntent(.resume)
      player._pauseProbeHookForTesting = { stage in
        guard stage == .nativePause else { return }
        player._pauseProbeHookForTesting = nil
        _ = player.eventBridge.synchronizePlaybackGeneration(
          capturedGeneration + 1,
          media: nil
        )
      }

      #expect(!player.issuePause(playbackGeneration: capturedGeneration))
      #expect(player.pauseTransition == nil)
      #expect(player.pauseTransitionPlaybackGeneration == nil)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `An outgoing resume retry cannot clear a successor pause`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)
      player.setDeferredPauseCommand(.pause, playbackGeneration: 1)

      #expect(!player.issueResume(playbackGeneration: 0))
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == 1)
    }

    @Test
    func `Resume unpauses when a recovered successor pause already landed`() {
      let player = Player(instance: TestInstance.shared)
      let generation: UInt64 = 1
      player.sessionGeneration = generation
      _ = player.eventBridge.synchronizePlaybackGeneration(generation, media: nil)
      player._nativePlaybackStateOverrideForTesting = .paused
      player.setDeferredPauseCommand(.pause, playbackGeneration: generation)
      player.publishPlaybackIntent(false)

      #expect(player.issueResume())
      #expect(player.deferredPauseCommand == nil)
      #expect(player.pauseTransition == .resuming)
      #expect(player.pauseTransitionPlaybackGeneration == generation)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `External media adoption carries pause intent to the successor`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        state: .playing,
        nativeState: .opening,
        isPlaybackRequestedActive: true
      )
      player.setPlaybackControlIntent(.pause)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)

      player.handleEvent(.mediaChanged, sourcePlaybackGeneration: 1)

      #expect(player.sessionGeneration == 1)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == 1)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `External media adoption preserves active intent through its queued-state gap`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        state: .paused,
        nativeState: .playing,
        isPlaybackRequestedActive: false
      )
      player.setPlaybackControlIntent(.resume)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)

      player.handleEvent(.mediaChanged, sourcePlaybackGeneration: 1)

      #expect(player.sessionGeneration == 1)
      #expect(player.state == .playing)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `External media adoption retains resume until a late pause settles`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        state: .playing,
        nativeState: .opening,
        isPlaybackRequestedActive: false
      )
      player.setPlaybackControlIntent(.resume)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)

      player.handleEvent(.mediaChanged, sourcePlaybackGeneration: 1)

      #expect(player.deferredPauseCommand == .resume)
      #expect(player.deferredPauseCommandPlaybackGeneration == 1)
      #expect(player.isPlaybackRequestedActive)

      player._nativePlaybackStateOverrideForTesting = .paused
      player.performDeferredPauseCommandIfNeeded()

      #expect(player.deferredPauseCommand == nil)
      #expect(player.pauseTransition == .resuming)
      #expect(player.pauseTransitionPlaybackGeneration == 1)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Media adoption preserves an in-flight pause transition for its generation`() {
      let player = Player(instance: TestInstance.shared)
      let adoptedGeneration: UInt64 = 1
      player.sessionGeneration = adoptedGeneration
      _ = player.eventBridge.synchronizePlaybackGeneration(adoptedGeneration, media: nil)
      player.setPauseTransition(.pausing, playbackGeneration: adoptedGeneration)

      player.resetMediaDerivedState()

      #expect(player.pauseTransition == .pausing)
      #expect(player.pauseTransitionPlaybackGeneration == adoptedGeneration)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `A queued pause overrides an older resume transition during adoption`() {
      let player = Player(instance: TestInstance.shared)
      let adoptedGeneration: UInt64 = 1
      player.sessionGeneration = adoptedGeneration
      _ = player.eventBridge.synchronizePlaybackGeneration(adoptedGeneration, media: nil)
      player.setPauseTransition(.resuming, playbackGeneration: adoptedGeneration)
      player.setDeferredPauseCommand(.pause, playbackGeneration: adoptedGeneration)
      player.publishPlaybackIntent(true)

      player.resetMediaDerivedState()

      #expect(!player.isPlaybackRequestedActive)
      #expect(player.pauseTransition == .resuming)
      #expect(player.deferredPauseCommand == .pause)
    }

    @Test
    func `A queued resume overrides an older pause transition during adoption`() {
      let player = Player(instance: TestInstance.shared)
      let adoptedGeneration: UInt64 = 1
      player.sessionGeneration = adoptedGeneration
      _ = player.eventBridge.synchronizePlaybackGeneration(adoptedGeneration, media: nil)
      player.setPauseTransition(.pausing, playbackGeneration: adoptedGeneration)
      player.setDeferredPauseCommand(.resume, playbackGeneration: adoptedGeneration)
      player.publishPlaybackIntent(false)

      player.resetMediaDerivedState()

      #expect(player.isPlaybackRequestedActive)
      #expect(player.pauseTransition == .pausing)
      #expect(player.deferredPauseCommand == .resume)
    }

    @Test
    func `An intermediate adoption preserves pause work for a later queued item`() {
      let player = Player(instance: TestInstance.shared)
      player.sessionGeneration = 1
      _ = player.eventBridge.synchronizePlaybackGeneration(2, media: nil)
      player.setPauseTransition(.pausing, playbackGeneration: 2)
      player.setDeferredPauseCommand(.resume, playbackGeneration: 2)

      player.resetMediaDerivedState()

      #expect(player.pauseTransition == .pausing)
      #expect(player.pauseTransitionPlaybackGeneration == 2)
      #expect(player.deferredPauseCommand == .resume)
      #expect(player.deferredPauseCommandPlaybackGeneration == 2)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Pause cancels an older queued resume when cached playback is paused`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused, isPlaybackRequestedActive: true)
      player.setDeferredPauseCommand(.resume, playbackGeneration: player.sessionGeneration)

      player.pause()

      #expect(player.deferredPauseCommand == nil)
      #expect(player.deferredPauseCommandPlaybackGeneration == nil)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Media adoption cancels an outgoing in-flight pause transition`() {
      let player = Player(instance: TestInstance.shared)
      player.setPauseTransition(.pausing, playbackGeneration: 0)
      let adoptedGeneration: UInt64 = 1
      player.sessionGeneration = adoptedGeneration
      _ = player.eventBridge.synchronizePlaybackGeneration(adoptedGeneration, media: nil)

      player.resetMediaDerivedState()

      #expect(player.pauseTransition == nil)
      #expect(player.pauseTransitionPlaybackGeneration == nil)
    }

    @Test
    func `Retrying an outgoing deferred command cancels before touching the successor`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .opening)
      player.setDeferredPauseCommand(.pause, playbackGeneration: 0)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)

      player.performDeferredPauseCommandIfNeeded()

      #expect(player.deferredPauseCommand == nil)
      #expect(player.deferredPauseCommandPlaybackGeneration == nil)
    }

    @Test
    func `Outgoing terminal event preserves a successor pause command`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.eventBridge.synchronizePlaybackGeneration(1, media: nil)
      player.setDeferredPauseCommand(.pause, playbackGeneration: 1)

      player._handleEventForTesting(.stateChanged(.stopped))

      #expect(player.deferredPauseCommand == .pause)
      #expect(player.deferredPauseCommandPlaybackGeneration == 1)
    }

    @Test
    func `Media adoption cancels a pause from the outgoing generation`() {
      let player = Player(instance: TestInstance.shared)
      player.deferredPauseCommand = .pause
      let adoptedGeneration: UInt64 = 1
      player.sessionGeneration = adoptedGeneration
      _ = player.eventBridge.synchronizePlaybackGeneration(adoptedGeneration, media: nil)

      player.resetMediaDerivedState()

      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `Multiple stop calls don't crash`() {
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      let player = Player(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let list = MediaList()
      listPlayer.mediaList = list
      // Call stop multiple times in succession
      listPlayer.stop()
      listPlayer.stop()
      listPlayer.stop()
      // No crash = success
    }
  }
}
