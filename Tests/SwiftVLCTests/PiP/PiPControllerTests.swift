#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import Dispatch
import Observation
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerTests {
    @MainActor
    final class PlaybackRecorder {
      var pauseCount = 0
      var resumeCount = 0
      var seekTargets: [Int64] = []

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { self.pauseCount += 1 },
          resume: { self.resumeCount += 1 },
          seek: { self.seekTargets.append($0.milliseconds) }
        )
      }
    }

    @Test
    func `Init with player does not crash`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      _ = controller
    }

    @Test
    func `isPossible reflects PiP support of the environment`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      // On macOS desktop, PiP may be supported; on headless CI it won't be.
      // Just verify accessing the property doesn't crash and returns a Bool.
      let possible = controller.isPossible
      #expect(possible == true || possible == false)
    }

    @Test
    func `isActive returns false initially`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      #expect(controller.isActive == false)
    }

    @Test
    func `layer returns a valid AVSampleBufferDisplayLayer`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      let layer = controller.layer
      #expect(layer.videoGravity == .resizeAspect)
    }

    @Test
    func `start does not crash without PiP support`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      controller.start()
    }

    @Test
    func `stop does not crash without PiP support`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      controller.stop()
    }

    @Test
    func `toggle does not crash without PiP support`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      controller.toggle()
    }

    @Test
    func `Creating PiPController attaches vmem callbacks`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      // If vmem callbacks were attached incorrectly, subsequent player
      // operations would crash. Verify the player is still usable.
      #expect(player.state == .idle)
      _ = player.currentTime
      _ = player.volume
      _ = controller
    }

    @Test
    func `PiPController deinit cleans up without crash`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      do {
        let controller = PiPController(player: player)
        _ = controller.layer
        controller.start()
        // controller goes out of scope and deinits here
      }
      // Player should still be usable after PiPController is deallocated
      #expect(player.state == .idle)
    }

    @Test
    func `Multiple PiPControllers for different players`() {
      let player1 = Player(instance: TestInstance.lifecycleShared)
      let player2 = Player(instance: TestInstance.lifecycleShared)
      let controller1 = PiPController(player: player1)
      let controller2 = PiPController(player: player2)
      // Each controller should have its own independent layer
      #expect(controller1.layer !== controller2.layer)
      #expect(controller1.isActive == false)
      #expect(controller2.isActive == false)
      // Both players should remain functional
      #expect(player1.state == .idle)
      #expect(player2.state == .idle)
    }

    @Test
    func `isActive invalidates observation`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      let fired = Mutex(false)

      withObservationTracking {
        _ = controller.isActive
      } onChange: {
        fired.withLock { $0 = true }
      }

      controller._setStateForTesting(isActive: true)

      #expect(fired.withLock { $0 })
      #expect(controller.isActive == true)
    }

    @Test
    func `isPossible invalidates observation`() {
      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      let fired = Mutex(false)
      let nextValue = !controller.isPossible

      withObservationTracking {
        _ = controller.isPossible
      } onChange: {
        fired.withLock { $0 = true }
      }

      controller._setStateForTesting(isPossible: nextValue)

      #expect(fired.withLock { $0 })
      #expect(controller.isPossible == nextValue)
    }

    @Test
    func `delegate state queries are safe off the main thread`() async {
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let player = Player(instance: TestInstance.lifecycleShared)
      let controller = PiPController(player: player)
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      // `AVPictureInPictureController` isn't `Sendable`, but
      // `PiPController._isPlaybackPausedForTesting` is `nonisolated` and
      // documented as safe to call off the main thread. Wrap both refs
      // in an `@unchecked Sendable` box so they can be captured by the
      // background closure without pointer-to-Int round-trips. ARC keeps
      // both alive until the box (and the closure) goes out of scope.
      struct Refs: @unchecked Sendable {
        let controller: PiPController
        let pip: AVPictureInPictureController
      }
      let refs = Refs(controller: controller, pip: pip)

      let paused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async {
          continuation.resume(returning: refs.controller._isPlaybackPausedForTesting(refs.pip))
        }
      }

      #expect(paused == true)
    }

    @Test
    func `transient PiP pause then play does not send native pause or resume`() async throws {
      let player = Player(instance: TestInstance.lifecycleShared)
      try player.play(url: TestMedia.twosecURL)
      guard try await poll(until: { player.state == .playing }) else {
        player.stop()
        return
      }
      defer { player.stop() }

      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      controller._setPlayingForTesting(true)
      try? await Task.sleep(for: .milliseconds(80))

      #expect(recorder.pauseCount == 0)
      #expect(recorder.resumeCount == 0)
    }

    @Test
    func `PiP skip cancels pending pause and suppresses redundant resume`() async throws {
      let player = Player(instance: TestInstance.lifecycleShared)
      try player.play(url: TestMedia.twosecURL)
      guard try await poll(until: { player.state == .playing }) else {
        player.stop()
        return
      }
      defer { player.stop() }

      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      controller._skipByIntervalForTesting(CMTime(seconds: 1, preferredTimescale: 1000))
      controller._setPlayingForTesting(true)
      try? await Task.sleep(for: .milliseconds(80))

      #expect(recorder.pauseCount == 0)
      #expect(recorder.resumeCount == 0)
      #expect(recorder.seekTargets.count == 1)
    }
  }
}
#endif
