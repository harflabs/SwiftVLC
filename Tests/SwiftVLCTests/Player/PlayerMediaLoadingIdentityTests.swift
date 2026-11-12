@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

private func nativeMediaAddress(on player: Player) -> UInt? {
  guard let media = libvlc_media_player_get_media(player.pointer) else {
    return nil
  }
  defer { libvlc_media_release(media) }
  return UInt(bitPattern: media)
}

private func waitForMediaLoadingSemaphore(
  _ semaphore: DispatchSemaphore
)
  async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(
        returning: semaphore.wait(timeout: .now() + 5) == .success
      )
    }
  }
}

/// Media loading is also a native PiP identity boundary. These tests prove
/// that a handle which may already own a vout is never relabelled in place as
/// another playback generation, while the cheap pristine path stays intact.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerMediaLoadingIdentityTests {
    @Test
    func `A pristine drawable handle installs media without replacement`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      let originalPointer = player.pointer
      let media = try Media(url: TestMedia.silenceURL)
      let mediaAddress = UInt(bitPattern: media.pointer)

      player.load(media)

      #expect(player.pointer == originalPointer)
      #expect(!player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(nativeMediaAddress(on: player) == mediaAddress)
    }

    @Test
    func `Loading after a hosted output defers native media to a fresh handle`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      let first = try Media(url: TestMedia.silenceURL)
      let firstAddress = UInt(bitPattern: first.pointer)
      player.load(first)
      #expect(nativeMediaAddress(on: player) == firstAddress)

      // This monotonic bit is set only after native play accepts. It models
      // the hard case without asking a headless unit test to manufacture a
      // real video output.
      player.nativePlayerHasStartedPlayback = true
      let usedPointer = player.pointer
      let successor = try Media(url: TestMedia.twosecURL)
      let successorAddress = UInt(bitPattern: successor.pointer)
      player.load(successor)

      #expect(player.currentMedia === successor)
      #expect(player.pointer == usedPointer)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(
        nativeMediaAddress(on: player) == firstAddress,
        "the used native handle was retrospectively relabelled with successor media"
      )

      try player.prepareDrawableForPlayback()

      #expect(player.pointer != usedPointer)
      #expect(!player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(nativeMediaAddress(on: player) == successorAddress)
    }

    @Test
    func `Deferred load reports replacement rather than its internal stop`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      let outgoingGeneration = PlaybackGeneration(player.sessionGeneration)

      // A started drawable handle must be stopped before its successor media
      // can be installed safely. That stop is an implementation detail of
      // `load(_:)`, not an explicit stop request made by the application.
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .playing, nativeState: .playing)
      try player.load(Media(url: TestMedia.twosecURL))

      #expect(player.terminalCause(for: outgoingGeneration) == .replacement)
    }

    @Test
    func `Deferred successor quarantines every retiring handle callback until reattach`()
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.silenceURL)
      let successor = try Media(url: TestMedia.twosecURL)
      let laterSuccessor = try Media(url: TestMedia.testMP4URL)
      let outgoingGeneration = bridge.synchronizePlaybackGeneration(
        1,
        media: first.pointer
      )
      let firstDormantGeneration = bridge.synchronizePlaybackGeneration(
        outgoingGeneration &+ 1,
        media: successor.pointer,
        outgoingNativeHandleGeneration: bridge.currentNativeHandleGeneration,
        expectRetiringHandleStopped: true
      )
      let currentDormantGeneration = bridge.synchronizePlaybackGeneration(
        firstDormantGeneration &+ 1,
        media: laterSuccessor.pointer,
        outgoingNativeHandleGeneration: bridge.currentNativeHandleGeneration,
        expectRetiringHandleStopped: true
      )
      let sourcedEvents = bridge.makeSourcedStream(policy: .unbounded)
      var iterator = sourcedEvents.makeAsyncIterator()
      let didBroadcastEnd = Mutex(false)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          didBroadcastEnd.withLock { $0 = true }
        }
        return false
      }

      var mediaStopping = libvlc_event_t()
      mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      var stopping = libvlc_event_t()
      stopping.type = Int32(libvlc_MediaPlayerStopping.rawValue)
      var playing = libvlc_event_t()
      playing.type = Int32(libvlc_MediaPlayerPlaying.rawValue)
      var vout = libvlc_event_t()
      vout.type = Int32(libvlc_MediaPlayerVout.rawValue)
      vout.u.media_player_vout.new_count = 1
      var seekable = libvlc_event_t()
      seekable.type = Int32(libvlc_MediaPlayerSeekableChanged.rawValue)
      seekable.u.media_player_seekable_changed.new_seekable = 1
      var tracks = libvlc_event_t()
      tracks.type = Int32(libvlc_MediaPlayerESUpdated.rawValue)
      var delayedMediaChanged = libvlc_event_t()
      delayedMediaChanged.type = Int32(libvlc_MediaPlayerMediaChanged.rawValue)
      delayedMediaChanged.u.media_player_media_changed.new_media = first.pointer
      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      var postStoppedVout = libvlc_event_t()
      postStoppedVout.type = Int32(libvlc_MediaPlayerVout.rawValue)
      postStoppedVout.u.media_player_vout.new_count = 0
      let retiringEvents = [
        mediaStopping,
        stopping,
        playing,
        vout,
        seekable,
        tracks,
        delayedMediaChanged,
        stopped,
        postStoppedVout
      ]
      for event in retiringEvents {
        bridge._emitNativeEventForTesting(event)
      }

      var sourced: [SourcedPlayerEvent] = []
      for _ in retiringEvents {
        try sourced.append(#require(await iterator.next()))
      }
      #expect(sourced.allSatisfy { $0.playbackGeneration == outgoingGeneration })
      #expect(sourced.contains {
        if case .mediaChanged = $0.event {
          true
        } else {
          false
        }
      })
      #expect(sourced.contains {
        if case .stateChanged(.stopping) = $0.event {
          true
        } else {
          false
        }
      })
      #expect(sourced.contains {
        if case .stateChanged(.playing) = $0.event {
          true
        } else {
          false
        }
      })
      #expect(sourced.contains {
        if case .voutChanged(0) = $0.event {
          true
        } else {
          false
        }
      })
      #expect(sourced.contains {
        if case .seekableChanged(true) = $0.event {
          true
        } else {
          false
        }
      })
      #expect(sourced.contains {
        if case .tracksChanged = $0.event {
          true
        } else {
          false
        }
      })
      #expect(bridge.currentPlaybackGeneration == currentDormantGeneration)
      #expect(bridge.terminalCause(for: outgoingGeneration) == .replacement)
      #expect(bridge.terminalCause(for: firstDormantGeneration) == .replacement)
      #expect(bridge.terminalCause(for: currentDormantGeneration) == nil)
      #expect(!didBroadcastEnd.withLock { $0 })
      withExtendedLifetime(endObservation) {}

      // Detach is the proof boundary: after it returns, the retiring producer
      // can no longer borrow the old attachment. The first callback on the
      // replacement attachment must therefore regain the current generation
      // and be accepted by Player's observable mirror.
      let replacementInstance = TestInstance.makeAudioOnly()
      let replacementPointer = try #require(
        libvlc_media_player_new(replacementInstance.pointer)
      )
      defer {
        bridge.invalidate()
        libvlc_media_player_release(replacementPointer)
      }
      let replacementEventManager = try #require(
        libvlc_media_player_event_manager(replacementPointer)
      )
      let oldNativeGeneration = bridge.currentNativeHandleGeneration
      let newNativeGeneration = bridge.reattach(to: replacementEventManager)
      #expect(newNativeGeneration > oldNativeGeneration)

      let successorEvents = bridge.makeSourcedStream(policy: .unbounded)
      var successorIterator = successorEvents.makeAsyncIterator()
      bridge._emitNativeEventForTesting(playing)
      let successorEvent = try #require(await successorIterator.next())
      #expect(successorEvent.nativeHandleGeneration == newNativeGeneration)
      #expect(successorEvent.playbackGeneration == currentDormantGeneration)

      player.sessionGeneration = currentDormantGeneration
      player._setStateForTesting(state: .idle, nativeState: .idle)
      player.handleSourcedEvent(successorEvent)
      #expect(player.state == .playing)
    }

    @Test
    func `Natural end reserved before deferred replacement still emits end reached`()
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.silenceURL)
      let successor = try Media(url: TestMedia.twosecURL)
      let outgoingGeneration = bridge.synchronizePlaybackGeneration(
        1,
        media: first.pointer
      )
      let didBroadcastEnd = Mutex(false)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          didBroadcastEnd.withLock { $0 = true }
        }
        return false
      }

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }
      let firstAddress = UInt(bitPattern: first.pointer)
      let callback = Task.detached {
        var mediaStopping = libvlc_event_t()
        mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
        mediaStopping.u.media_player_media_stopping.media = OpaquePointer(
          bitPattern: firstAddress
        )
        mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
        bridge._emitNativeEventForTesting(mediaStopping)
      }
      try #require(await waitForMediaLoadingSemaphore(entered))

      let successorGeneration = bridge.synchronizePlaybackGeneration(
        outgoingGeneration &+ 1,
        media: successor.pointer,
        outgoingNativeHandleGeneration: bridge.currentNativeHandleGeneration,
        expectRetiringHandleStopped: true
      )
      release.signal()
      await callback.value
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)

      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      bridge._emitNativeEventForTesting(stopped)

      #expect(bridge.terminalCause(for: outgoingGeneration) == .naturalEnd)
      #expect(bridge.terminalCause(for: successorGeneration) == nil)
      #expect(didBroadcastEnd.withLock { $0 })
      withExtendedLifetime(endObservation) {}
    }

    @Test
    func `List suppression is frozen before callback reservation for Stopped`()
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.silenceURL)
      let outgoingGeneration = bridge.synchronizePlaybackGeneration(
        1,
        media: first.pointer
      )
      let publicEndCount = Mutex(0)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          publicEndCount.withLock { $0 += 1 }
        }
        return false
      }
      player.endCoordinator.setSuppressed(true)
      defer { player.endCoordinator.setSuppressed(false) }

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }
      let firstAddress = UInt(bitPattern: first.pointer)
      let callback = Task.detached {
        var mediaStopping = libvlc_event_t()
        mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
        mediaStopping.u.media_player_media_stopping.media = OpaquePointer(
          bitPattern: firstAddress
        )
        mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
        bridge._emitNativeEventForTesting(mediaStopping)
      }
      try #require(await waitForMediaLoadingSemaphore(entered))

      // The callback has entered and captured its lifecycle reservation, but
      // has not yet classified/published the raw event. Detaching the list in
      // this window must not retroactively turn the list-item EOS into a
      // public natural end.
      player.endCoordinator.setSuppressed(false)
      release.signal()
      await callback.value
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)

      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      bridge._emitNativeEventForTesting(stopped)

      #expect(bridge.terminalCause(for: outgoingGeneration) == .naturalEnd)
      #expect(publicEndCount.withLock { $0 } == 0)
      withExtendedLifetime(endObservation) {}
    }

    @Test
    func `Duplicate natural terminal callbacks cannot synthesize a second end`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let media = try Media(url: TestMedia.silenceURL)
      _ = bridge.synchronizePlaybackGeneration(1, media: media.pointer)
      let publicEndCount = Mutex(0)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          publicEndCount.withLock { $0 += 1 }
        }
        return false
      }

      var mediaStopping = libvlc_event_t()
      mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      mediaStopping.u.media_player_media_stopping.media = media.pointer
      mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)

      bridge._emitNativeEventForTesting(mediaStopping)
      bridge._emitNativeEventForTesting(stopped)
      #expect(publicEndCount.withLock { $0 } == 1)

      bridge._emitNativeEventForTesting(mediaStopping)
      bridge._emitNativeEventForTesting(stopped)
      #expect(publicEndCount.withLock { $0 } == 1)
      withExtendedLifetime(endObservation) {}
    }

    @Test
    func `Reattach synthesizes a pre-replacement natural end exactly once`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.silenceURL)
      let successor = try Media(url: TestMedia.twosecURL)
      let outgoingGeneration = bridge.synchronizePlaybackGeneration(
        1,
        media: first.pointer
      )
      let oldNativeGeneration = bridge.currentNativeHandleGeneration
      let sourcedEvents = bridge.makeSourcedStream(policy: .unbounded)
      var sourcedIterator = sourcedEvents.makeAsyncIterator()
      let publicEndCount = Mutex(0)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          publicEndCount.withLock { $0 += 1 }
        }
        return false
      }

      // EOS is authoritative before replacement, but its ordered Stopped
      // callback intentionally never arrives from this attachment.
      var mediaStopping = libvlc_event_t()
      mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      mediaStopping.u.media_player_media_stopping.media = first.pointer
      mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      let firstTimelineRevision = bridge.advanceTimelineRevision()
      bridge._emitNativeEventForTesting(mediaStopping)
      let duplicateTimelineRevision = bridge.advanceTimelineRevision()
      bridge._emitNativeEventForTesting(mediaStopping)
      // Advance far enough to evict the outgoing cause from the bounded
      // diagnostic history. The exact pending emission token must retain its
      // own first-winner proof rather than depend on that cache.
      var successorGeneration = outgoingGeneration
      for offset in 1...40 {
        successorGeneration = bridge.synchronizePlaybackGeneration(
          outgoingGeneration &+ UInt64(offset),
          media: successor.pointer,
          outgoingNativeHandleGeneration: bridge.currentNativeHandleGeneration,
          expectRetiringHandleStopped: true
        )
      }

      let replacementInstance = TestInstance.makeAudioOnly()
      let replacementPointer = try #require(
        libvlc_media_player_new(replacementInstance.pointer)
      )
      defer {
        bridge.invalidate()
        libvlc_media_player_release(replacementPointer)
      }
      let replacementEventManager = try #require(
        libvlc_media_player_event_manager(replacementPointer)
      )
      let newNativeGeneration = bridge.reattach(to: replacementEventManager)
      #expect(publicEndCount.withLock { $0 } == 0)
      #expect(bridge.publishRetiredNaturalEndsAfterHandleReplacement() == 1)
      #expect(bridge.publishRetiredNaturalEndsAfterHandleReplacement() == 0)

      let stoppingEvent = try #require(await sourcedIterator.next())
      let duplicateStoppingEvent = try #require(await sourcedIterator.next())
      let synthesizedEnd = try #require(await sourcedIterator.next())
      #expect(stoppingEvent.playbackGeneration == outgoingGeneration)
      #expect(duplicateStoppingEvent.playbackGeneration == outgoingGeneration)
      #expect(synthesizedEnd.nativeHandleGeneration == oldNativeGeneration)
      #expect(synthesizedEnd.playbackGeneration == outgoingGeneration)
      #expect(synthesizedEnd.timelineRevision == firstTimelineRevision)
      #expect(synthesizedEnd.timelineRevision != duplicateTimelineRevision)
      if case .endReached = synthesizedEnd.event {
        // Expected.
      } else {
        Issue.record("reattach did not synthesize the pending natural end")
      }
      #expect(newNativeGeneration > oldNativeGeneration)
      #expect(bridge.currentPlaybackGeneration == successorGeneration)
      #expect(publicEndCount.withLock { $0 } == 1)

      // An unattributed stop from the successor cannot consume or replay the
      // retiring handle's already-delivered EOS.
      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      bridge._emitNativeEventForTesting(stopped)
      #expect(publicEndCount.withLock { $0 } == 1)
      withExtendedLifetime(endObservation) {}
    }

    @Test
    func `List suppression vetoes a pending natural end at reattach`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.silenceURL)
      let successor = try Media(url: TestMedia.twosecURL)
      let outgoingGeneration = bridge.synchronizePlaybackGeneration(
        1,
        media: first.pointer
      )
      let publicEndCount = Mutex(0)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          publicEndCount.withLock { $0 += 1 }
        }
        return false
      }
      player.endCoordinator.setSuppressed(true)
      defer { player.endCoordinator.setSuppressed(false) }

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }
      let firstAddress = UInt(bitPattern: first.pointer)
      let callback = Task.detached {
        var mediaStopping = libvlc_event_t()
        mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
        mediaStopping.u.media_player_media_stopping.media = OpaquePointer(
          bitPattern: firstAddress
        )
        mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
        bridge._emitNativeEventForTesting(mediaStopping)
      }
      try #require(await waitForMediaLoadingSemaphore(entered))

      // Freeze must happen before the callback can block in lifecycle
      // reservation or test hooks. A list detach in that gap cannot lift the
      // veto observed by the authoritative EOS.
      player.endCoordinator.setSuppressed(false)
      release.signal()
      await callback.value
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      _ = bridge.synchronizePlaybackGeneration(
        outgoingGeneration &+ 1,
        media: successor.pointer,
        outgoingNativeHandleGeneration: bridge.currentNativeHandleGeneration,
        expectRetiringHandleStopped: true
      )

      let replacementInstance = TestInstance.makeAudioOnly()
      let replacementPointer = try #require(
        libvlc_media_player_new(replacementInstance.pointer)
      )
      defer {
        bridge.invalidate()
        libvlc_media_player_release(replacementPointer)
      }
      let replacementEventManager = try #require(
        libvlc_media_player_event_manager(replacementPointer)
      )
      _ = bridge.reattach(to: replacementEventManager)
      #expect(bridge.publishRetiredNaturalEndsAfterHandleReplacement() == 0)

      #expect(publicEndCount.withLock { $0 } == 0)
      withExtendedLifetime(endObservation) {}
    }

    @Test
    func `Stopping a retiring handle cannot poison its dormant successor EOF`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .playing, nativeState: .playing)

      let successor = try Media(url: TestMedia.twosecURL)
      player.load(successor)
      let successorGeneration = player.sessionGeneration
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(player.nativePlayerReplacementHasCommittedMediaGeneration)

      // The native state still describes the retiring handle. Public stop
      // must tear that handle down without assigning its intent to the
      // successor generation, which has no native producer yet.
      player._setStateForTesting(state: .idle, nativeState: .stopping)
      player.stop()
      #expect(player.eventBridge.terminalCause(for: successorGeneration) == nil)
      #expect(
        !player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: successorGeneration
        )
      )

      #if DEBUG
      player._nativePlayOverrideForTesting = { 0 }
      #endif
      try player.play()
      #expect(player.sessionGeneration == successorGeneration)

      let didBroadcastEnd = Mutex(false)
      let endObservation = player.events(policy: .unbounded) { event in
        if case .endReached = event {
          didBroadcastEnd.withLock { $0 = true }
        }
        return false
      }
      var mediaStopping = libvlc_event_t()
      mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      mediaStopping.u.media_player_media_stopping.media = successor.pointer
      mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      player.eventBridge._emitNativeEventForTesting(mediaStopping)
      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      player.eventBridge._emitNativeEventForTesting(stopped)

      #expect(player.eventBridge.terminalCause(for: successorGeneration) == .naturalEnd)
      #expect(didBroadcastEnd.withLock { $0 })
      withExtendedLifetime(endObservation) {}
    }

    @Test
    func `Public play keeps the generation committed by deferred load`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .stopped, nativeState: .stopped)

      let usedPointer = player.pointer
      let successor = try Media(url: TestMedia.twosecURL)
      player.load(successor)
      let committedGeneration = player.sessionGeneration

      #if DEBUG
      player._nativePlayOverrideForTesting = { 0 }
      #endif
      try player.play()

      #expect(player.pointer != usedPointer)
      #expect(player.sessionGeneration == committedGeneration)
      #expect(player.eventBridge.currentPlaybackGeneration == committedGeneration)
      #expect(!player.nativePlayerReplacementHasCommittedMediaGeneration)

      // The marker is one-shot. A later stop and cold replay of the same media
      // must establish a genuinely new session instead of suppressing every
      // future generation boundary.
      player.stop()
      player._setStateForTesting(state: .stopped, nativeState: .stopped)
      try player.play()
      #expect(player.sessionGeneration == committedGeneration &+ 1)
      #expect(player.eventBridge.currentPlaybackGeneration == committedGeneration &+ 1)
    }

    @Test
    func `Live native state closes the list-player output race`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      let usedPointer = player.pointer

      // MediaListPlayer can start the handle without entering Player.play(),
      // so the wrapper's started bit can still be false while native open is
      // already able to snapshot the drawable identity.
      player._setStateForTesting(nativeState: .opening)
      let successor = try Media(url: TestMedia.twosecURL)
      let successorAddress = UInt(bitPattern: successor.pointer)
      player.load(successor)

      #expect(player.pointer == usedPointer)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(nativeMediaAddress(on: player) != successorAddress)
    }

    /// Previously pinned the opposite: an active handle with no drawable kept
    /// its pointer and took the new media directly. libVLC starts media
    /// assigned to a running player by itself, so that path played what
    /// `load(_:)` had only loaded. An active handle now waits for `play()`
    /// on a fresh handle whether or not it hosts a drawable.
    @Test
    func `An active audio-only handle defers loaded media to a fresh handle`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let originalPointer = player.pointer
      player._setStateForTesting(state: .playing)
      let successor = try Media(url: TestMedia.twosecURL)
      let successorAddress = UInt(bitPattern: successor.pointer)

      player.load(successor)

      #expect(player.pointer == originalPointer)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(!player.nativeHandleRepresentsCurrentMedia)
      #expect(player.currentMedia === successor)
      #expect(player.state == .idle)
      #expect(nativeMediaAddress(on: player) != successorAddress)
    }

    @Test
    func `An audio-only handle at rest takes loaded media directly`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      let originalPointer = player.pointer
      let successor = try Media(url: TestMedia.twosecURL)
      let successorAddress = UInt(bitPattern: successor.pointer)

      player.load(successor)

      #expect(player.pointer == originalPointer)
      #expect(!player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(player.currentMedia === successor)
      try await awaitNativeMediaSwitch(on: player, to: successor)
      #expect(nativeMediaAddress(on: player) == successorAddress)
    }

    #if os(iOS)
    @Test
    func `v9 publication rejection never assigns media under an unproven identity`() throws {
      Player._nativePiPV9AvailabilityOverrideForTesting = true
      Player._nativePiPIdentityPublicationOverrideForTesting = { _, _, _ in false }
      defer {
        Player._nativePiPV9AvailabilityOverrideForTesting = nil
        Player._nativePiPIdentityPublicationOverrideForTesting = nil
      }

      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      let originalPointer = player.pointer
      let media = try Media(url: TestMedia.silenceURL)

      player.load(media)

      #expect(player.currentMedia === media)
      #expect(player.pointer == originalPointer)
      #expect(nativeMediaAddress(on: player) == nil)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(player.nativePlayerReplacementHasCommittedMediaGeneration)

      do {
        try player.prepareDrawableForPlayback(
          successorPlaybackGeneration: PlaybackGeneration(player.sessionGeneration),
          playbackGenerationIsAlreadyCommitted: true
        )
        Issue.record("replacement unexpectedly committed a rejected v9 identity")
      } catch {
        #expect(error == .operationFailed("Publish native PiP playback identity"))
      }
      #expect(player.pointer == originalPointer)
      #expect(nativeMediaAddress(on: player) == nil)
    }

    @Test
    func `deferred load replacement publishes its already committed generation exactly`() throws {
      var published: [(generation: UInt64, handle: UInt64)] = []
      Player._nativePiPV9AvailabilityOverrideForTesting = true
      Player._nativePiPIdentityPublicationOverrideForTesting = { _, generation, handle in
        published.append((generation, handle))
        return true
      }
      defer {
        Player._nativePiPV9AvailabilityOverrideForTesting = nil
        Player._nativePiPIdentityPublicationOverrideForTesting = nil
      }

      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      let outgoingHandle = player.nativeHandleLifetime.nativePiPHandleIdentity
      published.removeAll()

      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .stopped, nativeState: .stopped)
      try player.load(Media(url: TestMedia.twosecURL))
      let committedGeneration = player.sessionGeneration
      player._nativePlayOverrideForTesting = { 0 }
      try player.play()

      let publication = try #require(published.last)
      #expect(publication.generation == committedGeneration)
      #expect(publication.handle == player.nativeHandleLifetime.nativePiPHandleIdentity)
      #expect(publication.handle != outgoingHandle)
      #expect(player.eventBridge.currentPlaybackGeneration == committedGeneration)
    }

    @Test
    func `cold replay publishes one exact successor generation before play`() throws {
      var published: [(generation: UInt64, handle: UInt64)] = []
      Player._nativePiPV9AvailabilityOverrideForTesting = true
      Player._nativePiPIdentityPublicationOverrideForTesting = { _, generation, handle in
        published.append((generation, handle))
        return true
      }
      defer {
        Player._nativePiPV9AvailabilityOverrideForTesting = nil
        Player._nativePiPIdentityPublicationOverrideForTesting = nil
      }

      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      let firstGeneration = player.sessionGeneration
      let outgoingHandle = player.nativeHandleLifetime.nativePiPHandleIdentity
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .stopped, nativeState: .stopped)
      player.stop()
      published.removeAll()
      player._nativePlayOverrideForTesting = { 0 }

      try player.play()

      let publication = try #require(published.last)
      #expect(publication.generation == firstGeneration &+ 1)
      #expect(player.sessionGeneration == firstGeneration &+ 1)
      #expect(player.eventBridge.currentPlaybackGeneration == firstGeneration &+ 1)
      #expect(publication.handle == player.nativeHandleLifetime.nativePiPHandleIdentity)
      #expect(publication.handle != outgoingHandle)
    }
    #endif
  }
}
