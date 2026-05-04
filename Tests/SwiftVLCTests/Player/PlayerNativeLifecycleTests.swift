@testable import SwiftVLC
import CLibVLC
import Foundation
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
