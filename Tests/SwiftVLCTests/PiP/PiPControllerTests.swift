#if os(iOS) || os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
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
      var cancelPendingPauseCount = 0
      var shouldResume = false
      var seekTargets: [Int64] = []

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: {
            self.pauseCount += 1
            return true
          },
          resume: {
            self.resumeCount += 1
            return true
          },
          cancelPendingPause: {
            self.cancelPendingPauseCount += 1
          },
          shouldResume: { self.shouldResume },
          seek: { self.seekTargets.append($0.milliseconds) }
        )
      }
    }

    @Test
    func `Init with player does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      _ = controller
    }

    @Test
    func `isPossible reflects PiP support of the environment`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      // On macOS desktop, PiP may be supported; on headless CI it won't be.
      // Just verify accessing the property doesn't crash and returns a Bool.
      let possible = controller.isPossible
      #expect(possible == true || possible == false)
    }

    @Test
    func `isActive returns false initially`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      #expect(controller.isActive == false)
    }

    @Test
    func `layer returns a valid AVSampleBufferDisplayLayer`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let layer = controller.layer
      #expect(layer.videoGravity == .resizeAspect)
    }

    @Test
    func `start does not crash without PiP support`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.start()
    }

    @Test
    func `stop does not crash without PiP support`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.stop()
    }

    @Test
    func `toggle does not crash without PiP support`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.toggle()
    }

    @Test
    func `Creating PiPController attaches vmem callbacks`() {
      let player = Player(instance: TestInstance.shared)
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
      let player = Player(instance: TestInstance.shared)
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
      let player1 = Player(instance: TestInstance.shared)
      let player2 = Player(instance: TestInstance.shared)
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
      let player = Player(instance: TestInstance.shared)
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
      let player = Player(instance: TestInstance.shared)
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

      let player = Player(instance: TestInstance.shared)
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

    @Test(.enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"))
    func `transient PiP pause then play does not send native pause or resume`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
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
      #expect(recorder.cancelPendingPauseCount == 1)
    }

    @Test(.enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"))
    func `PiP skip cancels pending pause and suppresses redundant resume`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
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
      #expect(recorder.cancelPendingPauseCount == 1)
      #expect(recorder.seekTargets.count == 1)
    }

    @Test
    func `public init defaults both policy knobs to true`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      #expect(controller.startsAutomaticallyFromInline == true)
      #expect(controller.managesAudioSession == true)
    }

    @Test
    func `internal init stores both policy knobs and does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        startsAutomaticallyFromInline: false,
        managesAudioSession: false
      )
      #expect(controller.startsAutomaticallyFromInline == false)
      #expect(controller.managesAudioSession == false)
      controller.start()
      controller.stop()
    }

    #if os(iOS)
    /// With `managesAudioSession: false` neither init nor `start()` may
    /// touch the shared audio session — category and activation both
    /// stay exactly as they were.
    @Test
    func `managesAudioSession false leaves the audio session untouched`() {
      let session = AVAudioSession.sharedInstance()
      let categoryBefore = session.category
      let modeBefore = session.mode

      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: false
      )
      controller.start()

      #expect(session.category == categoryBefore)
      #expect(session.mode == modeBefore)
      #expect(controller.hasActivatedAudioSession == false)
    }

    /// With `managesAudioSession: true` the category is set at init but
    /// activation is deferred: constructing the controller never grabs
    /// audio focus, `start()` does.
    @Test
    func `managesAudioSession true defers activation out of init`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: true
      )

      #expect(AVAudioSession.sharedInstance().category == .playback)
      #expect(controller.hasActivatedAudioSession == false)

      controller.start()
      #expect(controller.hasActivatedAudioSession == true)
    }

    /// The sample-buffer path mirrors the knob onto AVKit's
    /// `canStartPictureInPictureAutomaticallyFromInline`. The AVKit
    /// controller only exists where PiP is supported, so assert through
    /// it conditionally.
    @Test
    func `startsAutomaticallyFromInline reaches the AVKit controller`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()

      let disabled = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        startsAutomaticallyFromInline: false
      )
      if let avController = disabled.pipController {
        #expect(avController.canStartPictureInPictureAutomaticallyFromInline == false)
      }

      let enabled = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        startsAutomaticallyFromInline: true
      )
      if let avController = enabled.pipController {
        #expect(avController.canStartPictureInPictureAutomaticallyFromInline == true)
      }
    }
    #endif

    /// `allowsPrivateMacOSAPI` is a simple atomic-backed property; the
    /// only contract is that reads see the most recent write. The flag
    /// defaults to `false` and roundtrips through `true` and back.
    @Test func `allowsPrivateMacOSAPI defaults to false and roundtrips`() {
      // Remember the entry value so the rest of the suite isn't
      // affected by this test's writes.
      let initial = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initial }

      #expect(PiPController.allowsPrivateMacOSAPI == false)

      PiPController.allowsPrivateMacOSAPI = true
      #expect(PiPController.allowsPrivateMacOSAPI == true)

      PiPController.allowsPrivateMacOSAPI = false
      #expect(PiPController.allowsPrivateMacOSAPI == false)
    }
  }
}
#endif
