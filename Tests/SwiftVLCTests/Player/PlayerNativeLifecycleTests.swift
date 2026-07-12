@testable import SwiftVLC
import CLibVLC
import Foundation
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerNativeLifecycleTests {
    @Test
    func `shouldReplaceNativePlayerBeforePlaybackLoad is false without current media`() {
      let player = Player(instance: TestInstance.shared)

      player._setStateForTesting(state: .playing)

      #expect(player.shouldReplaceNativePlayerBeforePlaybackLoad == false)
    }

    @Test(
      arguments: [
        PlayerState.opening,
        .buffering,
        .playing,
        .paused,
        .stopping,
        .error
      ]
    )
    func `shouldReplaceNativePlayerBeforePlaybackLoad is true for active observed states`(
      state: PlayerState
    )
      throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))

      player._setStateForTesting(state: state)

      #expect(player.shouldReplaceNativePlayerBeforePlaybackLoad)
    }

    @Test(arguments: [PlayerState.idle, .stopped])
    func `shouldReplaceNativePlayerBeforePlaybackLoad is false for inactive observed and native states`(
      state: PlayerState
    )
      throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))

      player._setStateForTesting(state: state)

      #expect(player.shouldReplaceNativePlayerBeforePlaybackLoad == false)
    }

    @Test
    func `stopNativePlayerBeforeRelease resumes before stopping when requested`() {
      let player = Player(instance: TestInstance.shared)

      Player.stopNativePlayerBeforeRelease(player.pointer, resumeBeforeStop: true)

      #expect(player.state == .idle)
    }

    /// `shutdown()` clears `pauseTransition` before offloading native teardown.
    /// The decision to resume must therefore be captured while `.pausing` is
    /// still visible, even when libVLC has not published `.paused` yet.
    @Test
    func `pending native pause requires resume before teardown`() {
      let player = Player(instance: TestInstance.shared)
      player.pauseTransition = .pausing

      #expect(player.nativePlaybackState != .paused)
      #expect(player.shouldResumeNativePlayerBeforeStop)

      player.pauseTransition = nil
      #expect(player.shouldResumeNativePlayerBeforeStop == false)
    }

    @Test
    func `Native handle release waits for every counted native owner`() throws {
      let pointer = try #require(OpaquePointer(bitPattern: 0x51A2_ED00))
      let lifetime = NativePlayerHandleLifetime(pointer: pointer)
      let listPlayerLease = lifetime.acquireNativeOwnerLease()
      let actionCount = Mutex(0)
      weak var retainedProbe: NSObject?

      do {
        let probe = NSObject()
        retainedProbe = probe
        lifetime.retainUntilReleased([probe])
      }
      lifetime.whenReleased {
        actionCount.withLock { $0 += 1 }
      }

      lifetime.initialOwnerDidRelease()

      #expect(lifetime.nativeOwnerCount == 1)
      #expect(!lifetime.isReleased)
      #expect(actionCount.withLock { $0 } == 0)
      #expect(retainedProbe != nil)

      listPlayerLease.endAfterNativeOwnerRelease()

      #expect(lifetime.nativeOwnerCount == 0)
      #expect(lifetime.isReleased)
      #expect(actionCount.withLock { $0 } == 1)
      #expect(retainedProbe == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Native lifetime hands final retained-object release to the main thread`() async throws {
      let pointer = try #require(OpaquePointer(bitPattern: 0x51A2_ED01))
      let lifetime = NativePlayerHandleLifetime(pointer: pointer)
      let additionalOwner = lifetime.acquireNativeOwnerLease()
      let deinitWasOnMainThread = Mutex<Bool?>(nil)
      weak var retainedProbe: DeinitThreadProbe?

      do {
        let probe = DeinitThreadProbe {
          deinitWasOnMainThread.withLock { $0 = Thread.isMainThread }
        }
        retainedProbe = probe
        lifetime.retainUntilReleased([probe])
      }

      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          lifetime.initialOwnerDidRelease()
          continuation.resume()
        }
      }
      #expect(lifetime.nativeOwnerCount == 1)
      #expect(retainedProbe != nil)

      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          additionalOwner.endAfterNativeOwnerRelease()
          continuation.resume()
        }
      }
      try #require(
        await poll(timeout: .seconds(10)) {
          deinitWasOnMainThread.withLock { $0 != nil }
        },
        "Waiting for: main-thread retained-object release"
      )

      #expect(lifetime.isReleased)
      #expect(retainedProbe == nil)
      #expect(deinitWasOnMainThread.withLock { $0 } == true)
    }

    @Test
    func `direct drawable attachment and clearing maintain ownership`() {
      let player = Player(instance: TestInstance.shared)
      let drawable = NSObject()
      let unrelated = NSObject()

      player.setDrawable(drawable)
      #expect(player.isCurrentDrawable(drawable))
      #expect(player.isDrawableOwner(drawable))

      player.clearDrawable(ifCurrent: unrelated)
      #expect(player.isCurrentDrawable(drawable))

      player.clearDrawable(ifCurrent: drawable)
      #expect(player.drawable == nil)
      #expect(!player.isDrawableOwner(drawable))
    }

    /// libVLC reads `drawable-nsobject` asynchronously. Once a handle has
    /// started, clearing the variable cannot prove that a vout which already
    /// copied the raw pointer has finished retaining or messaging it. Keep the
    /// outgoing drawable alive until that exact native handle is released.
    @Test
    func `detaching drawable from a list-owned handle retains it until full native release`() async {
      let player = Player(instance: TestInstance.shared)
      let listPlayer = MediaListPlayer(instance: TestInstance.shared)
      listPlayer.mediaPlayer = player
      let lifetime = player.nativeHandleLifetime
      weak var weakDrawable: NSObject?

      do {
        let drawable = NSObject()
        weakDrawable = drawable
        player.setDrawable(drawable)
        // Deterministically model the state set immediately after a successful
        // libvlc_media_player_play call without opening a real CI video output.
        player.nativePlayerHasStartedPlayback = true
        player.setDrawable(nil)
        player.setDrawable(drawable)
        player.setDrawable(nil)
        #expect(player.retainedDrawablesUntilNativePlayerRelease.count == 1)
      }

      #expect(weakDrawable != nil)
      await player.shutdown()
      #expect(lifetime.isReleased)
      #expect(listPlayer.mediaPlayer == nil)
      #expect(weakDrawable == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Coupled list-player and player deinit keep drawable until both native releases finish`() async throws {
      let instance = TestInstance.makeAudioOnly()
      var player: Player? = Player(instance: instance)
      var listPlayer: MediaListPlayer? = MediaListPlayer(instance: instance)
      let lifetime = try #require(player?.nativeHandleLifetime)
      weak let weakPlayer = player
      weak var weakDrawable: NSObject?

      do {
        let drawable = NSObject()
        weakDrawable = drawable
        player?.setDrawable(drawable)
        player?.nativePlayerHasStartedPlayback = true
        player?.setDrawable(nil)
      }
      listPlayer?.mediaPlayer = player
      #expect(lifetime.nativeOwnerCount == 2)
      #expect(weakDrawable != nil)

      listPlayer = nil
      player = nil

      try #require(
        await poll(timeout: .seconds(10)) { lifetime.isReleased },
        "Waiting for: list-player and player native releases"
      )
      #expect(lifetime.nativeOwnerCount == 0)
      #expect(weakPlayer == nil)
      #expect(weakDrawable == nil)
    }

    /// A replacement handle and its predecessor tear down on independent
    /// utility-queue jobs. Holding a real extra native retain keeps the
    /// predecessor alive after the successor has fully shut down, proving the
    /// drawable is leased by the predecessor's lifetime rather than merely by
    /// the current `Player.drawable` property.
    @Test(.timeLimit(.minutes(1)))
    func `Replacement retains current drawable until the outgoing native handle releases`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let oldPointer = player.pointer
      let oldLifetime = player.nativeHandleLifetime
      let oldLease = oldLifetime.acquireNativeOwnerLease()
      _ = libvlc_media_player_retain(oldPointer)
      var oldLeaseDidEnd = false
      defer {
        if !oldLeaseDidEnd {
          libvlc_media_player_release(oldPointer)
          oldLease.endAfterNativeOwnerRelease()
        }
      }
      weak var weakDrawable: NSObject?

      do {
        let drawable = NSObject()
        weakDrawable = drawable
        player.setDrawable(drawable)
        // Deterministically model an old vout that copied the drawable without
        // requiring a window server or timing-sensitive decoder in CI.
        player.nativePlayerHasStartedPlayback = true

        try player.replaceNativePlayerForDrawablePlayback(target: drawable)
        player.setDrawable(nil)
      }

      await player.shutdown()
      try #require(
        await poll(timeout: .seconds(10)) { oldLifetime.nativeOwnerCount == 1 },
        "Waiting for: outgoing Swift owner release"
      )
      #expect(weakDrawable != nil)

      libvlc_media_player_release(oldPointer)
      oldLease.endAfterNativeOwnerRelease()
      oldLeaseDidEnd = true

      #expect(oldLifetime.isReleased)
      #expect(weakDrawable == nil)
    }

    /// Each outgoing generation owns only its own drawable lease. Three rapid
    /// replacements are then released in a deliberately different order to
    /// prove that no global/current-handle retain accidentally makes the test
    /// pass through FIFO queue timing.
    @Test(.timeLimit(.minutes(1)))
    func `Rapid replacements release drawable leases in exact native handle order`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let drawable0 = StrongReferenceBox(NSObject())
      weak let weakDrawable0 = drawable0.value
      try player.setDrawable(requireValue(in: drawable0))
      player.nativePlayerHasStartedPlayback = true
      let pointer0 = player.pointer
      let lifetime0 = player.nativeHandleLifetime
      let lease0 = lifetime0.acquireNativeOwnerLease()
      _ = libvlc_media_player_retain(pointer0)
      var lease0DidEnd = false
      defer {
        if !lease0DidEnd {
          libvlc_media_player_release(pointer0)
          lease0.endAfterNativeOwnerRelease()
        }
      }
      try player.replaceNativePlayerForDrawablePlayback(target: drawable0.value)

      let drawable1 = StrongReferenceBox(NSObject())
      weak let weakDrawable1 = drawable1.value
      try player.setDrawable(requireValue(in: drawable1))
      drawable0.value = nil
      player.nativePlayerHasStartedPlayback = true
      let pointer1 = player.pointer
      let lifetime1 = player.nativeHandleLifetime
      let lease1 = lifetime1.acquireNativeOwnerLease()
      _ = libvlc_media_player_retain(pointer1)
      var lease1DidEnd = false
      defer {
        if !lease1DidEnd {
          libvlc_media_player_release(pointer1)
          lease1.endAfterNativeOwnerRelease()
        }
      }
      try player.replaceNativePlayerForDrawablePlayback(target: drawable1.value)

      let drawable2 = StrongReferenceBox(NSObject())
      weak let weakDrawable2 = drawable2.value
      try player.setDrawable(requireValue(in: drawable2))
      drawable1.value = nil
      player.nativePlayerHasStartedPlayback = true
      let pointer2 = player.pointer
      let lifetime2 = player.nativeHandleLifetime
      let lease2 = lifetime2.acquireNativeOwnerLease()
      _ = libvlc_media_player_retain(pointer2)
      var lease2DidEnd = false
      defer {
        if !lease2DidEnd {
          libvlc_media_player_release(pointer2)
          lease2.endAfterNativeOwnerRelease()
        }
      }
      try player.replaceNativePlayerForDrawablePlayback(target: drawable2.value)

      player.setDrawable(nil)
      drawable2.value = nil
      await player.shutdown()
      try #require(
        await poll(timeout: .seconds(10)) {
          lifetime0.nativeOwnerCount == 1
            && lifetime1.nativeOwnerCount == 1
            && lifetime2.nativeOwnerCount == 1
        },
        "Waiting for: all outgoing Swift owner releases"
      )
      #expect(weakDrawable0 != nil)
      #expect(weakDrawable1 != nil)
      #expect(weakDrawable2 != nil)

      // Finish H1 before H0: only H1's drawable may disappear.
      libvlc_media_player_release(pointer1)
      lease1.endAfterNativeOwnerRelease()
      lease1DidEnd = true
      #expect(lifetime1.isReleased)
      #expect(weakDrawable0 != nil)
      #expect(weakDrawable1 == nil)
      #expect(weakDrawable2 != nil)

      libvlc_media_player_release(pointer0)
      lease0.endAfterNativeOwnerRelease()
      lease0DidEnd = true
      #expect(lifetime0.isReleased)
      #expect(weakDrawable0 == nil)
      #expect(weakDrawable2 != nil)

      libvlc_media_player_release(pointer2)
      lease2.endAfterNativeOwnerRelease()
      lease2DidEnd = true
      #expect(lifetime2.isReleased)
      #expect(weakDrawable2 == nil)
    }

    @Test
    func `prepareDrawableForPlayback rebinds drawable when requested`() throws {
      let player = Player(instance: TestInstance.shared)
      let drawable = NSObject()

      player.setDrawable(drawable)
      player.needsDrawableRebindForPlayback = true

      try player.prepareDrawableForPlayback()

      #expect(player.isCurrentDrawable(drawable))
      #expect(player.needsDrawableRebindForPlayback == false)
    }

    @Test
    func `stop marks hosted drawable for rebind before later playback`() {
      let player = Player(instance: TestInstance.shared)
      let drawable = NSObject()

      player.setDrawable(drawable)
      player.stop()

      #expect(player.needsDrawableRebindForPlayback)
    }

    @Test
    func `deferred pause commands are consumed when performed`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      player.deferredPauseCommand = .pause

      player.performDeferredPauseCommandIfNeeded()

      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `deferred resume commands are consumed when performed`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      player.deferredPauseCommand = .resume

      player.performDeferredPauseCommandIfNeeded()

      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `syncCurrentMediaFromNative clears stale current media when native player has none`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      libvlc_media_player_set_media(player.pointer, nil)

      player.syncCurrentMediaFromNative()

      #expect(player.currentMedia == nil)
    }
  }
}

private final class DeinitThreadProbe: @unchecked Sendable {
  private let onDeinit: @Sendable () -> Void

  init(onDeinit: @escaping @Sendable () -> Void) {
    self.onDeinit = onDeinit
  }

  deinit {
    onDeinit()
  }
}

private final class StrongReferenceBox<Value: AnyObject> {
  var value: Value?

  init(_ value: Value) {
    self.value = value
  }
}

private func requireValue<Value: AnyObject>(
  in box: StrongReferenceBox<Value>
)
  throws -> Value {
  try #require(box.value)
}
