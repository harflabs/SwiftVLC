// swiftlint:disable file_length
#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import CLibVLC
import CoreMedia
import CustomDump
import Synchronization
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
      var pauseResult = true
      var shouldResume = false
      var resumeResult = true
      var seekTargets: [Int64] = []

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: {
            self.pauseCount += 1
            return self.pauseResult
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

    private func makePictureInPictureController(
      for controller: PiPController
    ) -> AVPictureInPictureController? {
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      return AVPictureInPictureController(contentSource: contentSource)
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

    @Test
    func `deferred PiP pause retries while native pause is rejected`() async throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let recorder = PlaybackRecorder()
      recorder.pauseResult = false
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      try? await Task.sleep(for: .milliseconds(20))
      controller._setPlayingForTesting(false)

      #expect(try await poll(every: .milliseconds(10), timeout: .milliseconds(250)) {
        recorder.pauseCount >= 2
      })

      controller._setPlayingForTesting(true)
    }

    @Test
    func `external play intent clears previously issued PiP pause`() async throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      try? await Task.sleep(for: .milliseconds(20))
      controller._setPlayingForTesting(false)

      #expect(try await poll(every: .milliseconds(10), timeout: .milliseconds(250)) {
        recorder.pauseCount == 1
      })

      player.setPlaybackIntentFromExternalControl(true)

      #expect(try await poll(every: .milliseconds(10), timeout: .milliseconds(250)) {
        controller._pipPlaybackActiveForTesting()
      })

      controller._setPlayingForTesting(true)

      #expect(recorder.resumeCount == 0)
    }

    @Test
    func `external pause intent supersedes pending PiP play request`() async throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(true)
      #expect(controller._pendingPiPPlaybackStateForTesting() == true)

      player.setPlaybackIntentFromExternalControl(false)

      #expect(try await poll(every: .milliseconds(10), timeout: .milliseconds(250)) {
        controller._pendingPiPPlaybackStateForTesting() == false
      })
      #expect(controller._pipPlaybackActiveForTesting() == false)
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

    @Test
    func `PiPController deinit defers renderer cleanup for an active cached player`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)

      do {
        let controller = PiPController(player: player)
        _ = controller.layer
      }

      #expect(player.state == .playing)
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

    @Test
    func `skip interval conversion rejects nonnumeric Core Media times`() {
      #expect(PiPController.skipOffsetMilliseconds(.invalid) == nil)
      #expect(PiPController.skipOffsetMilliseconds(.indefinite) == nil)
      #expect(PiPController.skipOffsetMilliseconds(.positiveInfinity) == nil)
      #expect(PiPController.skipOffsetMilliseconds(.negativeInfinity) == nil)
    }

    @Test
    func `skip target arithmetic saturates before timeline clamp`() {
      #expect(
        PiPController.clampedSkipTargetMilliseconds(
          current: Int64.max - 5,
          offset: 10,
          duration: nil
        ) == Int64.max
      )
      #expect(
        PiPController.clampedSkipTargetMilliseconds(
          current: 5,
          offset: Int64.min,
          duration: nil
        ) == 0
      )
      #expect(
        PiPController.clampedSkipTargetMilliseconds(
          current: Int64.max,
          offset: Int64.max,
          duration: 10000
        ) == 10000
      )
    }

    @Test
    func `playback delegate proxy forwards setPlaying to owner`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )
      guard let pip = makePictureInPictureController(for: controller) else { return }

      controller._playbackDelegateForTesting.pictureInPictureController(pip, setPlaying: false)

      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._pendingPiPPlaybackStateForTesting() == false)
    }

    @Test
    func `playback delegate proxy forwards skip to owner`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(20))
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250)
      )
      guard let pip = makePictureInPictureController(for: controller) else { return }
      let didComplete = Mutex(false)

      controller._playbackDelegateForTesting.pictureInPictureController(
        pip,
        skipByInterval: CMTime(seconds: 2, preferredTimescale: 1000)
      ) {
        didComplete.withLock { $0 = true }
      }

      expectNoDifference(recorder.seekTargets, [7000])
      #expect(didComplete.withLock { $0 })
    }

    @Test
    func `playback delegate proxy completes skip when owner is gone`() {
      let proxy = PiPPlaybackDelegateProxy()
      let layer = AVSampleBufferDisplayLayer()
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer,
        playbackDelegate: proxy
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)
      let didComplete = Mutex(false)

      proxy.pictureInPictureController(
        pip,
        skipByInterval: CMTime(seconds: 10, preferredTimescale: 1000)
      ) {
        didComplete.withLock { $0 = true }
      }

      #expect(didComplete.withLock { $0 })
    }

    // MARK: - Delegate TimeRangeForPlayback

    /// With no media loaded there is no playable content. AVKit's
    /// sample-buffer playback-delegate contract requires an invalid range
    /// for this state.
    @Test
    func `timeRangeForPlayback is invalid when no media is loaded`() {
      let expected = PiPPlaybackDelegateProxy.playbackTimeRange(
        hasMedia: false,
        duration: nil
      )
      #expect(!expected.isValid)

      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      let range = controller._timeRangeForPlaybackForTesting(pip)

      #expect(range == expected)
    }

    /// A loaded input whose duration is still unknown is live/indefinite
    /// content, not an empty controller. AVKit requires an infinite duration
    /// so it renders linear live controls instead of a fabricated VOD range.
    @Test
    func `timeRangeForPlayback is infinite when loaded media duration is unknown`() throws {
      let expected = PiPPlaybackDelegateProxy.playbackTimeRange(
        hasMedia: true,
        duration: nil
      )
      #expect(expected.isValid)
      #expect(expected.duration.isPositiveInfinity)

      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      let range = controller._timeRangeForPlaybackForTesting(pip)

      #expect(range == expected)
    }

    /// The repository's released v0.10 binary predates the additive atomic
    /// symbol. After parsing and loading a real VOD, the compatibility path
    /// must still report the duration stored on that retained media object.
    @Test(.tags(.async, .media))
    func `released binary fallback reports loaded parsed VOD duration`() async throws {
      guard !swiftvlc_media_length_snapshot_available() else { return }

      let media = try Media(url: TestMedia.twosecURL)
      _ = try await media.parse(timeout: .seconds(5), instance: TestInstance.shared)
      let expectedMilliseconds = libvlc_media_get_duration(media.pointer)
      #expect(expectedMilliseconds > 0)

      let player = Player(instance: TestInstance.shared)
      player.load(media)
      let range = PiPPlaybackDelegateProxy.nativePlaybackTimeRange(
        playerPointer: player.pointer
      )

      #expect(range.isValid)
      #expect(range.duration.isNumeric)
      #expect(
        abs(range.duration.seconds - Double(expectedMilliseconds) / 1000) < 0.001
      )
    }

    /// An unparsed network input has no finite duration. The same released-
    /// binary fallback must distinguish that loaded identity from no media and
    /// report a live/indefinite range.
    @Test(.tags(.media))
    func `released binary fallback reports loaded unknown stream as live`() throws {
      guard !swiftvlc_media_length_snapshot_available() else { return }

      let url = try #require(URL(string: "http://127.0.0.1:1/swiftvlc-live-proof"))
      let media = try Media(url: url)
      #expect(libvlc_media_get_duration(media.pointer) <= 0)

      let player = Player(instance: TestInstance.shared)
      player.load(media)
      let range = PiPPlaybackDelegateProxy.nativePlaybackTimeRange(
        playerPointer: player.pointer
      )

      #expect(range.isValid)
      #expect(range.duration.isPositiveInfinity)
    }

    /// A retained native media snapshot with a finite libVLC length maps to
    /// the matching AVKit playback range and balances the media reference.
    @Test
    func `timeRangeForPlayback reports native duration when known`() throws {
      let retainedMedia = try #require(OpaquePointer(bitPattern: 0x1))
      var releaseCount = 0
      let range = try PiPPlaybackDelegateProxy.playbackTimeRange(
        playerPointer: #require(OpaquePointer(bitPattern: 0x2)),
        getSnapshot: { _ in (retainedMedia, 120_000) },
        releaseMedia: { media in
          #expect(media == retainedMedia)
          releaseCount += 1
        }
      )

      #expect(range.start == .zero)
      #expect(abs(range.duration.seconds - 120) < 0.01)
      #expect(releaseCount == 1)
    }

    /// When the additive atomic symbol is absent, the compatibility path must
    /// ask duration about the same retained media object returned by the
    /// player. Calling the independent player-length API would reintroduce the
    /// replacement race this snapshot is designed to remove.
    @Test
    func `legacy snapshot reads duration from the retained media identity`() throws {
      let player = try #require(OpaquePointer(bitPattern: 0x10))
      let retainedMedia = try #require(OpaquePointer(bitPattern: 0x20))
      var atomicCalls = 0
      var durationInputs: [OpaquePointer] = []

      let snapshot = PiPPlaybackDelegateProxy.retainedMediaLengthSnapshot(
        playerPointer: player,
        atomicSnapshotAvailable: false,
        getAtomicSnapshot: { _ in
          atomicCalls += 1
          return nil
        },
        getRetainedMedia: { receivedPlayer in
          #expect(receivedPlayer == player)
          return retainedMedia
        },
        getMediaDuration: { media in
          durationInputs.append(media)
          return 120_000
        }
      )

      #expect(snapshot?.media == retainedMedia)
      #expect(snapshot?.length == 120_000)
      #expect(atomicCalls == 0)
      #expect(durationInputs == [retainedMedia])
    }

    /// Once the additive symbol exists, a failed atomic query means no loaded
    /// media. Falling through to legacy calls could mix identities across a
    /// concurrent replacement, so the operation must fail closed.
    @Test
    func `available atomic snapshot never falls through to legacy calls`() throws {
      let player = try #require(OpaquePointer(bitPattern: 0x10))
      var retainedMediaCalls = 0

      let snapshot = PiPPlaybackDelegateProxy.retainedMediaLengthSnapshot(
        playerPointer: player,
        atomicSnapshotAvailable: true,
        getAtomicSnapshot: { receivedPlayer in
          #expect(receivedPlayer == player)
          return nil
        },
        getRetainedMedia: { _ in
          retainedMediaCalls += 1
          return OpaquePointer(bitPattern: 0x20)
        },
        getMediaDuration: { _ in 120_000 }
      )

      #expect(snapshot == nil)
      #expect(retainedMediaCalls == 0)
    }

    /// Core Media ranges exclude their end. A timebase exactly at duration,
    /// or a briefly advanced timebase awaiting the terminal player event,
    /// therefore requires a minimally extended finite answer for AVKit's
    /// documented contains-current-time invariant.
    @Test(arguments: [120.0, 120.25])
    func `finite playback range contains timebase at and beyond nominal end`(
      currentSeconds: Double
    ) {
      let current = CMTime(seconds: currentSeconds, preferredTimescale: 1000)
      let range = PiPPlaybackDelegateProxy.playbackTimeRange(
        hasMedia: true,
        duration: .seconds(120),
        currentTime: current
      )

      #expect(range.isValid)
      #expect(range.duration.isNumeric)
      #expect(CMTimeRangeContainsTime(range, time: current))
    }

    // MARK: - Delegate size transition hook

    /// AVKit reports PiP window-size changes through the playback delegate.
    /// The forwarding path must remain safe even when the platform does not
    /// need macOS's target-sized buffer rendering path.
    @Test
    func `didTransitionToRenderSize does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      controller._didTransitionToRenderSizeForTesting(
        pip,
        size: CMVideoDimensions(width: 320, height: 240)
      )
    }

    @Test
    func `didTransitionToRenderSize updates renderer target size only on sample resizing platforms`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      controller._didTransitionToRenderSizeForTesting(
        pip,
        size: CMVideoDimensions(width: 512, height: 288)
      )

      let renderSize = controller._renderSizeForTesting()
      #if os(macOS)
      #expect(renderSize?.width == 512)
      #expect(renderSize?.height == 288)
      #else
      #expect(renderSize == nil)
      #endif
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
      guard let pip = makePictureInPictureController(for: controller) else { return }

      #expect(controller.isActive == false)
      controller.pictureInPictureControllerDidStartPictureInPicture(pip)
      #expect(controller.isActive == true)
    }

    @Test
    func `willStartPictureInPicture syncs playback state`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      player._setStateForTesting(isPlaybackRequestedActive: true)
      controller.pictureInPictureControllerWillStartPictureInPicture(pip)

      #expect(controller._pipPlaybackActiveForTesting() == true)
    }

    @Test
    func `didStopPictureInPicture clears isActive`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller._setStateForTesting(isActive: true)
      guard let pip = makePictureInPictureController(for: controller) else { return }

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
      guard let pip = makePictureInPictureController(for: controller) else { return }

      let fakeError = NSError(domain: "swiftvlc.test", code: 42)
      controller.pictureInPictureController(pip, failedToStartPictureInPictureWithError: fakeError)
      #expect(controller.isActive == false)
    }

    /// With no `onRestoreUserInterface` hook, AVKit's completion handler
    /// must still fire — with `true` — so PiP tears down instead of
    /// hanging.
    @Test
    func `restoreUserInterface completes with true when no hook is set`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      let restored = Mutex<Bool?>(nil)
      controller.pictureInPictureController(
        pip,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { value in restored.withLock { $0 = value } }
      )

      #expect(restored.withLock { $0 } == true)
    }

    /// The host's restore hook is invoked, and the success value it passes
    /// to its completion is forwarded verbatim to AVKit.
    @Test
    func `restoreUserInterface forwards host success to AVKit`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      let hookCalled = Mutex(false)
      controller.onRestoreUserInterface = { done in
        hookCalled.withLock { $0 = true }
        done(true)
      }

      let restored = Mutex<Bool?>(nil)
      controller.pictureInPictureController(
        pip,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { value in restored.withLock { $0 = value } }
      )

      #expect(hookCalled.withLock { $0 })
      #expect(restored.withLock { $0 } == true)
    }

    /// A host that fails to restore its UI passes `false`, which must reach
    /// AVKit so the system can react accordingly.
    @Test
    func `restoreUserInterface forwards host failure to AVKit`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      guard let pip = makePictureInPictureController(for: controller) else { return }

      controller.onRestoreUserInterface = { done in
        done(false)
      }

      let restored = Mutex<Bool?>(nil)
      controller.pictureInPictureController(
        pip,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { value in restored.withLock { $0 = value } }
      )

      #expect(restored.withLock { $0 } == false)
    }

    @Test
    func `terminal observed state clears stale pending PiP play request`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._setPlayingForTesting(true)
      player._setStateForTesting(state: .error)
      controller._handleObservedPlaybackActivityForTesting(false)

      #expect(controller._pipPlaybackActiveForTesting() == false)
      #expect(controller._pendingPiPPlaybackStateForTesting() == nil)
    }

    @Test
    func `observed playback activity mirrors external active changes without pending PiP state`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(
        player: player,
        playbackDriver: PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250)
      )

      controller._handleObservedPlaybackActivityForTesting(true)
      #expect(controller._pipPlaybackActiveForTesting() == true)

      controller._handleObservedPlaybackActivityForTesting(false)
      #expect(controller._pipPlaybackActiveForTesting() == false)
    }
  }
}
#endif
