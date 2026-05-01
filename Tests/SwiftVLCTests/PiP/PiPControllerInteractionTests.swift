#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import CoreMedia
import CustomDump
import Testing

/// Complements `PiPControllerTests` by exercising the delegate /
/// playback-driver paths that the existing suite only partially
/// covers. Uses `PiPController.PlaybackDriver` injection so tests can
/// assert on translated commands without needing libVLC to actually
/// reach `.playing` (which is flaky in headless CI).
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerInteractionTests {
    @MainActor
    final class PlaybackRecorder {
      var pauseCount = 0
      var resumeCount = 0
      var cancelPendingPauseCount = 0
      var shouldResume = false
      var resumeResult = true
      var seekTargets: [Int64] = []

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: {
            self.pauseCount += 1
            return true
          },
          resume: {
            self.resumeCount += 1
            return self.resumeResult
          },
          cancelPendingPause: {
            self.cancelPendingPauseCount += 1
          },
          shouldResume: { self.shouldResume },
          seek: { self.seekTargets.append($0.milliseconds) }
        )
      }
    }

    // MARK: - handleSetPlaying

    /// Setting `playing: false` when the player is `.idle` must NOT
    /// issue a native pause — there's nothing to pause. The deferred
    /// pause task gates on `player.state == .playing`, so idle short-
    /// circuits the driver.
    @Test
    func `setPlaying false while idle does not issue native pause`() async {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._setPlayingForTesting(false)
      // Wait longer than the debounce so the scheduled task resolves.
      try? await Task.sleep(for: .milliseconds(40))

      #expect(recorder.pauseCount == 0, "Idle player should not issue native pause")
    }

    /// Setting `playing: false` while the player is `.playing` must
    /// (after the debounce) call `playbackDriver.pause` exactly once.
    /// This exercises the `.playing` → pause path inside
    /// `scheduleDeferredPause`, which the idle-test above deliberately
    /// short-circuits.
    ///
    /// Note: the controller's state observer has a first-tick sync that
    /// sets `pipPlaybackActive = true` for a `.playing` player. We yield
    /// the scheduler briefly after construction so the observer settles
    /// before we drive `setPlaying(false)`, otherwise the observer's
    /// first tick could race with the deferred pause and flip the flag
    /// back to true.
    @Test
    func `setPlaying false while playing eventually issues native pause`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      // Let the observer settle its initial tick.
      try? await Task.sleep(for: .milliseconds(20))

      controller._setPlayingForTesting(false)
      try? await Task.sleep(for: .milliseconds(200))

      #expect(recorder.pauseCount == 1, "Debounced pause must fire once for a playing player")
    }

    /// After a real deferred pause has been issued, `setPlaying(true)`
    /// must call `playbackDriver.resume` exactly once — the
    /// `didIssueDeferredPause` flag tracks this state transition.
    @Test
    func `setPlaying true after an issued pause resumes playback`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      // Let the observer settle its initial tick.
      try? await Task.sleep(for: .milliseconds(20))

      controller._setPlayingForTesting(false)
      try? await Task.sleep(for: .milliseconds(200))
      #expect(recorder.pauseCount == 1)

      controller._setPlayingForTesting(true)
      try? await Task.sleep(for: .milliseconds(20))

      #expect(recorder.resumeCount == 1, "resume must fire after a previously-issued pause")
    }

    @Test
    func `setPlaying true resumes a native pause transition that is still in flight`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let recorder = PlaybackRecorder()
      recorder.shouldResume = true
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(true)

      #expect(recorder.resumeCount == 1)
      #expect(controller._pendingPiPPlaybackStateForTesting() == true)

      controller._handleObservedPlaybackActivityForTesting(false)

      #expect(controller._pipPlaybackActiveForTesting() == true)
      #expect(controller._pendingPiPPlaybackStateForTesting() == true)
    }

    @Test
    func `setPlaying true falls back to native state when resume is rejected`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      let recorder = PlaybackRecorder()
      recorder.shouldResume = true
      recorder.resumeResult = false
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(true)

      #expect(recorder.resumeCount == 1)
      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._pendingPiPPlaybackStateForTesting() == nil)
    }

    /// While `.buffering`, the deferred pause loop keeps waiting for
    /// libVLC to stabilize — it must NOT issue a pause yet, and must
    /// NOT give up. Verify by scheduling a pause while buffering and
    /// confirming no driver call fires within the wait window.
    @Test
    func `setPlaying false while buffering does not issue pause`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .buffering)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._setPlayingForTesting(false)
      try? await Task.sleep(for: .milliseconds(80))

      #expect(recorder.pauseCount == 0, "Buffering must not trigger a native pause")
    }

    // MARK: - toggle branches

    /// `toggle()` while PiP is active dispatches to `stop()`. Real
    /// teardown requires an actual PiP session, which headless tests
    /// can't start — the assertion is "doesn't crash".
    @Test
    func `toggle while active calls stop`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller._setStateForTesting(isActive: true)
      controller.toggle()
    }

    /// `toggle()` while PiP is inactive dispatches to `start()`.
    @Test
    func `toggle while inactive calls start`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.toggle()
    }

    // MARK: - deinit

    /// Explicit scope-drop so the PiPController deinits during the
    /// test. Exercises `isolated deinit` which does the libVLC
    /// callback detach and renderer cleanup. The test must NOT crash,
    /// and the player must remain usable afterwards.
    @Test
    func `PiPController deinit runs cleanup without crashing`() {
      let player = Player(instance: TestInstance.shared)
      do {
        let controller = PiPController(player: player)
        _ = controller.layer
      }
      // Player must still be usable — if the deinit left libVLC with
      // a dangling callback pointer, a subsequent operation would
      // crash here.
      #expect(player.state == .idle)
    }

    /// `pictureInPictureControllerIsPlaybackPaused` must read from the
    /// internal `pipPlaybackActive` flag, which `setPlaying` updates
    /// synchronously — not from libVLC's async state.
    @Test
    func `isPlaybackPaused flips synchronously after setPlaying`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250)
      )
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      controller._setPlayingForTesting(true)
      #expect(controller._isPlaybackPausedForTesting(pip) == false)

      controller._setPlayingForTesting(false)
      #expect(controller._isPlaybackPausedForTesting(pip) == true)
    }

    @Test
    func `setPlaying updates player playback intent synchronously`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(false)

      #expect(player.isPlaybackRequestedActive == false)
      #expect(controller._pipPlaybackActiveForTesting() == false)

      controller._setPlayingForTesting(true)

      #expect(player.isPlaybackRequestedActive == true)
      #expect(controller._pipPlaybackActiveForTesting() == true)
    }

    @Test
    func `external playback controls update PiP playback state`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPausable: false)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      #expect(controller._pipPlaybackActiveForTesting() == true)

      player.pause()
      try? await Task.sleep(for: .milliseconds(30))

      #expect(player.isPlaybackRequestedActive == false)
      #expect(controller._pipPlaybackActiveForTesting() == false)

      player.resume()
      try? await Task.sleep(for: .milliseconds(30))

      #expect(player.isPlaybackRequestedActive == true)
      #expect(controller._pipPlaybackActiveForTesting() == true)
    }

    @Test
    func `external pause intent does not freeze video timebase before native pause`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPausable: false)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      #expect(controller._controlTimebaseRateForTesting() == 1)

      player.pause()
      try? await Task.sleep(for: .milliseconds(30))

      #expect(player.isPlaybackRequestedActive == false)
      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._controlTimebaseRateForTesting() == 1)
    }

    @Test
    func `PiP pause intent does not freeze video timebase before native pause`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      #expect(controller._controlTimebaseRateForTesting() == 1)

      controller._setPlayingForTesting(false)

      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._controlTimebaseRateForTesting() == 1)
    }

    @Test
    func `pending PiP pause is not overwritten by stale playing observation`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(false)
      controller._handleObservedPlaybackActivityForTesting(true)

      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._pendingPiPPlaybackStateForTesting() == false)
    }

    @Test
    func `pending PiP pause clears when native playback reaches paused`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(false)
      player._setStateForTesting(state: .paused)
      controller._handleObservedPlaybackActivityForTesting(false)

      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._pendingPiPPlaybackStateForTesting() == nil)
    }

    @Test
    func `pending PiP play is not overwritten by stale paused observation`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(true)
      controller._handleObservedPlaybackActivityForTesting(false)

      #expect(controller._pipPlaybackActiveForTesting() == true)
      #expect(controller._pendingPiPPlaybackStateForTesting() == true)
    }

    // MARK: - handleSkip boundary conditions

    /// PiP skip at position 0 with a negative interval must clamp to 0,
    /// not go negative. The clamp lives in `handleSkip`.
    @Test
    func `skip backwards from zero clamps to zero`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: -10, preferredTimescale: 1000))

      expectNoDifference(recorder.seekTargets, [0])
    }

    /// Skip with a known duration must clamp at the upper bound when
    /// the interval would overshoot the end of the media.
    @Test
    func `skip past duration clamps to duration`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(9),
        duration: .seconds(10)
      )
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: 60, preferredTimescale: 1000))

      expectNoDifference(recorder.seekTargets, [10000])
    }

    /// A mid-range skip with neither clamp fires just the intended seek.
    @Test
    func `skip within bounds passes through unclamped`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(5),
        duration: .seconds(60)
      )
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      controller._skipByIntervalForTesting(CMTime(seconds: 3, preferredTimescale: 1000))

      expectNoDifference(recorder.seekTargets, [8000])
    }

    // MARK: - Delegate TimeRangeForPlayback

    /// Without a known duration, the delegate must report a 24-hour
    /// sentinel so the PiP scrubber doesn't collapse to 100%.
    @Test
    func `timeRangeForPlayback reports sentinel when duration is unknown`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      let range = controller._timeRangeForPlaybackForTesting(pip)

      #expect(range.start == .zero)
      #expect(range.duration.seconds >= 86399, "Should be approximately 24 hours")
    }

    /// When a duration is set, the delegate reports the matching range.
    @Test
    func `timeRangeForPlayback reports real duration when known`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(duration: .seconds(120))
      let controller = PiPController(player: player)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      let range = controller._timeRangeForPlaybackForTesting(pip)

      #expect(range.start == .zero)
      #expect(abs(range.duration.seconds - 120) < 0.01)
    }

    // MARK: - Delegate size transition hook

    /// AVKit reports PiP window-size changes through the playback delegate.
    /// The forwarding path must remain safe even when the platform does not
    /// need macOS's target-sized buffer rendering path.
    @Test
    func `didTransitionToRenderSize does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      controller._didTransitionToRenderSizeForTesting(
        pip,
        size: CMVideoDimensions(width: 320, height: 240)
      )
    }

    @Test
    func `didTransitionToRenderSize updates renderer target size`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      controller._didTransitionToRenderSizeForTesting(
        pip,
        size: CMVideoDimensions(width: 512, height: 288)
      )

      let renderSize = controller._renderSizeForTesting()
      #expect(renderSize?.width == 512)
      #expect(renderSize?.height == 288)
    }

    // MARK: - AVPictureInPictureControllerDelegate

    /// `pictureInPictureControllerDidStartPictureInPicture` must mirror
    /// the active flag into observation. The delegate bridge uses
    /// `withMainActorSync`, so this test posts from the test's main
    /// actor and verifies the state flip.
    @Test
    func `didStartPictureInPicture sets isActive`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      #expect(controller.isActive == false)
      controller.pictureInPictureControllerDidStartPictureInPicture(pip)
      #expect(controller.isActive == true)
    }

    @Test
    func `didStopPictureInPicture clears isActive`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller._setStateForTesting(isActive: true)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      #expect(controller.isActive == true)
      controller.pictureInPictureControllerDidStopPictureInPicture(pip)
      #expect(controller.isActive == false)
    }

    /// `failedToStartPictureInPicture` also clears the active flag so
    /// UI doesn't stay stuck in a "starting" limbo after an error.
    @Test
    func `failedToStartPictureInPicture clears isActive`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller._setStateForTesting(isActive: true)
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      let fakeError = NSError(domain: "swiftvlc.test", code: 42)
      controller.pictureInPictureController(pip, failedToStartPictureInPictureWithError: fakeError)
      #expect(controller.isActive == false)
    }
  }
}
#endif
