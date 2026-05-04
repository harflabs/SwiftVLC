@testable import SwiftVLC
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
    ) throws {
      let player = Player(instance: TestInstance.shared)
      player.load(try Media(url: TestMedia.twosecURL))

      player._setStateForTesting(state: state)

      #expect(player.shouldReplaceNativePlayerBeforePlaybackLoad)
    }

    @Test(arguments: [PlayerState.idle, .stopped])
    func `shouldReplaceNativePlayerBeforePlaybackLoad is false for inactive observed and native states`(
      state: PlayerState
    ) throws {
      let player = Player(instance: TestInstance.shared)
      player.load(try Media(url: TestMedia.twosecURL))

      player._setStateForTesting(state: state)

      #expect(player.shouldReplaceNativePlayerBeforePlaybackLoad == false)
    }

    @Test
    func `stopNativePlayerBeforeRelease resumes before stopping when requested`() {
      let player = Player(instance: TestInstance.shared)

      Player.stopNativePlayerBeforeRelease(player.pointer, resumeBeforeStop: true)

      #expect(player.state == .idle)
    }
  }
}
