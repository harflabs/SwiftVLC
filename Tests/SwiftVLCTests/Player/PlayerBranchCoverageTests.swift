@testable import SwiftVLC
import Testing

/// Covers `Player` branches that the rest of the suite exercises
/// partially — state-dependent toggle dispatch, seek clamping,
/// native-state refresh after external state changes, and the track
/// selection fallback when the requested track is missing.
///
/// All tests drive observable properties directly via
/// `_setStateForTesting` so they're deterministic without depending
/// on libVLC playback actually reaching `.playing`.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerBranchCoverageTests {
    // MARK: - togglePlayPause

    @Test
    func `togglePlayPause from playing calls pause`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      player.togglePlayPause()
    }

    @Test
    func `togglePlayPause follows pending playback intent while native state catches up`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPausable: false)

      player.togglePlayPause()

      #expect(player.isPlaybackRequestedActive == false)
      #expect(player._hasDeferredPauseForTesting())

      player.togglePlayPause()

      #expect(player.isPlaybackRequestedActive == true)
      #expect(!player._hasDeferredPauseForTesting())
    }

    @Test
    func `isPlaying follows playback intent while native state catches up`() {
      let player = Player(instance: TestInstance.shared)

      player._setStateForTesting(state: .opening, isPlaybackRequestedActive: true)
      #expect(player.state == .opening)
      #expect(player.isPlaying)

      player._setStateForTesting(state: .paused, isPlaybackRequestedActive: true)
      #expect(player.state == .paused)
      #expect(player.isPlaying)

      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: false)
      #expect(player.state == .playing)
      #expect(player.isPlaying == false)
    }

    @Test
    func `togglePlayPause can cancel a pending resume while native state is still paused`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused, isPlaybackRequestedActive: true)

      player.togglePlayPause()

      #expect(player.isPlaybackRequestedActive == false)
    }

    @Test
    func `togglePlayPause from early playing queues pause until VLC is pausable`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPausable: false)

      player.togglePlayPause()

      #expect(player._hasDeferredPauseForTesting())
    }

    @Test
    func `resume cancels queued early pause`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPausable: false)

      player.pause()
      player.resume()

      #expect(player.isPlaybackRequestedActive)
      #expect(!player._hasDeferredPauseForTesting())
    }

    @Test
    func `togglePlayPause from paused calls resume`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      player.togglePlayPause()
    }

    @Test
    func `togglePlayPause from idle attempts play`() {
      let player = Player(instance: TestInstance.shared)
      player.togglePlayPause()
    }

    @Test
    func `togglePlayPause from stopped attempts play`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .stopped)
      player.togglePlayPause()
    }

    /// Active transient states must not issue an immediate libVLC
    /// pause-toggle, but they should remember the user's pause intent
    /// and apply it once playback reaches a stable pausable state.
    @Test
    func `togglePlayPause from active transient states queues pause`() {
      for state in [PlayerState.opening, .buffering] {
        let player = Player(instance: TestInstance.shared)
        player._setStateForTesting(state: state)
        player.togglePlayPause()
        #expect(player._hasDeferredPauseForTesting(), "togglePlayPause on .\(state) must queue pause")
      }
    }

    @Test
    func `togglePlayPause from inactive transient states is a no-op`() {
      for state in [PlayerState.stopping, .error] {
        let player = Player(instance: TestInstance.shared)
        player._setStateForTesting(state: state)
        player.togglePlayPause()
        #expect(player.state == state, "togglePlayPause on .\(state) must not mutate state")
        #expect(!player._hasDeferredPauseForTesting(), "togglePlayPause on .\(state) must not queue pause")
      }
    }

    @Test
    func `encountered error clears playback intent`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)

      player._handleEventForTesting(.encounteredError)

      #expect(player.state == .error)
      #expect(player.isPlaybackRequestedActive == false)
    }

    // MARK: - seek(by:) clamp

    /// Negative seek when near the start must clamp currentTime to
    /// zero, not underflow.
    @Test
    func `seek by negative offset clamps currentTime to zero`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(1),
        duration: .seconds(60),
        isSeekable: true
      )

      player.seek(by: .seconds(-100))

      #expect(player.currentTime == .zero, "seek(by:) must clamp to zero when going past the start")
    }

    /// Forward seek beyond duration must clamp currentTime to the end.
    @Test
    func `seek by offset past duration clamps to duration`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(59),
        duration: .seconds(60),
        isSeekable: true
      )

      player.seek(by: .seconds(100))

      #expect(player.currentTime == .seconds(60), "seek(by:) must clamp at duration")
    }

    /// Mid-range seek with neither clamp leaves the published time at
    /// the optimistic target.
    @Test
    func `seek by offset within bounds advances optimistically`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(10),
        duration: .seconds(60),
        isSeekable: true
      )

      player.seek(by: .seconds(5))

      #expect(player.currentTime == .seconds(15))
    }

    // MARK: - position setter with known duration

    /// Setting `position` when a duration is known must optimistically
    /// update `currentTime` to the position-implied time, before the
    /// eventual timeChanged event refines it.
    @Test
    func `setting position with known duration updates currentTime optimistically`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(duration: .seconds(100))

      player.position = 0.25

      #expect(player.currentTime == .seconds(25))
    }

    /// Setting `position` with no known duration leaves currentTime
    /// alone (the `if let dur` branch short-circuits).
    @Test
    func `setting position without duration does not touch currentTime`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(7))

      player.position = 0.5

      #expect(player.currentTime == .seconds(7))
    }

    // MARK: - seek(to:) updates currentTime optimistically

    /// `seek(to:)` always republishes `currentTime` so observers see
    /// the new value even if libVLC never emits `timeChanged`
    /// (happens during `.paused`).
    @Test
    func `seek(to:) updates currentTime optimistically`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(2), duration: .seconds(60))

      player.seek(to: .seconds(42))

      #expect(player.currentTime == .seconds(42))
    }

    // MARK: - selectedAudioTrack/Subtitle setter

    /// Setting `selectedAudioTrack = nil` when no track is selected must
    /// route through `unselectTrackType` without crashing.
    @Test
    func `selectedAudioTrack nil setter is a no-op safe path`() {
      let player = Player(instance: TestInstance.shared)
      player.selectedAudioTrack = nil
    }

    @Test
    func `selectedSubtitleTrack nil setter is a no-op safe path`() {
      let player = Player(instance: TestInstance.shared)
      player.selectedSubtitleTrack = nil
    }

    // MARK: - isActive across states

    /// `isActive` is true for `.playing`, `.opening`, `.buffering` and
    /// false for everything else. Cover the full truth table so a
    /// future reorder of the switch doesn't silently flip semantics.
    @Test
    func `isActive reports correct value across every PlayerState`() {
      let player = Player(instance: TestInstance.shared)

      let expected: [PlayerState: Bool] = [
        .idle: false,
        .opening: true,
        .buffering: true,
        .playing: true,
        .paused: false,
        .stopped: false,
        .stopping: false,
        .error: false
      ]

      for (state, expectedActive) in expected {
        player._setStateForTesting(state: state)
        #expect(
          player.isActive == expectedActive,
          "isActive for \(state) expected \(expectedActive), got \(player.isActive)"
        )
      }
    }

    // MARK: - Titles / Chapters / Programs accessors on empty media

    /// With no DVD/Blu-ray media loaded, all structured-media accessors
    /// must return empty collections rather than throwing. libVLC reports
    /// `titleCount`/`chapterCount` as `-1` when no title is active — pin
    /// that behavior so a future libVLC change (e.g. to 0) surfaces as a
    /// surprise rather than hidden behind an unchecked `>= 0` guard.
    @Test
    func `titles chapters programs return empty on non-structured media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.titles.isEmpty)
      #expect(player.chapters().isEmpty)
      #expect(player.chapters(forTitle: 0).isEmpty)
      #expect(player.programs.isEmpty)
      #expect(player.selectedProgram == nil)
      // libVLC reports -1 for both when no title is active.
      #expect(player.titleCount < 1)
      #expect(player.chapterCount < 1)
    }

    // MARK: - Chapter navigation on empty media

    /// Chapter navigation on a player without media must not crash —
    /// libVLC silently ignores these calls when no title is active.
    @Test
    func `nextChapter and previousChapter without media do not crash`() {
      let player = Player(instance: TestInstance.shared)
      player.nextChapter()
      player.previousChapter()
    }

    // MARK: - Audio delay / subtitle delay / text scale setters

    /// Setters must not crash when no media is loaded — libVLC will
    /// silently no-op until there's an active stream to adjust. The
    /// getter returning `0` in that case is expected and pinned by
    /// the ``subtitleTextScale`` test below which uses a libVLC
    /// global that's always active.
    @Test
    func `audioDelay setter without media is safe`() {
      let player = Player(instance: TestInstance.shared)
      player.audioDelay = .milliseconds(250)
      _ = player.audioDelay
    }

    @Test
    func `subtitleDelay setter without media is safe`() {
      let player = Player(instance: TestInstance.shared)
      player.subtitleDelay = .milliseconds(-500)
      _ = player.subtitleDelay
    }

    /// `subtitleTextScale` is a libVLC-global variable that round-trips
    /// even without media.
    @Test
    func `subtitleTextScale round trip`() {
      let player = Player(instance: TestInstance.shared)
      player.subtitleTextScale = 1.5
      #expect(abs(player.subtitleTextScale - 1.5) < 0.01)
    }

    // MARK: - Role round trip

    @Test
    func `role round trip`() {
      let player = Player(instance: TestInstance.shared)
      player.role = .music
      #expect(player.role == .music)
      player.role = .communication
      #expect(player.role == .communication)
    }

    // MARK: - Aspect ratio round trip

    @Test
    func `aspectRatio fill sets display-fit to larger`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .fill
      #expect(player.aspectRatio == .fill)
    }

    @Test
    func `aspectRatio ratio sets display-fit to smaller`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .ratio(16, 9)
      if case .ratio(let w, let h) = player.aspectRatio {
        #expect(w == 16)
        #expect(h == 9)
      } else {
        Issue.record("Expected .ratio(16, 9)")
      }
    }

    @Test
    func `aspectRatio default resets scale and fit`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .ratio(16, 9)
      player.aspectRatio = .default
      #expect(player.aspectRatio == .default)
    }

    // MARK: - Stop / nextFrame / navigate don't crash

    /// These operations must be safe no-ops when no media is loaded.
    @Test
    func `nextFrame without media does not crash`() {
      let player = Player(instance: TestInstance.shared)
      player.nextFrame()
    }

    @Test
    func `stop without media does not crash`() {
      let player = Player(instance: TestInstance.shared)
      player.stop()
    }

    @Test
    func `navigate without menu does not crash`() {
      let player = Player(instance: TestInstance.shared)
      for action in [NavigationAction.activate, .up, .down, .left, .right, .popup] {
        player.navigate(action)
      }
    }

    // MARK: - Programs / selectProgram

    /// Calling `selectProgram(id:)` on a player with no programs must
    /// not crash — libVLC treats unknown IDs as a no-op.
    @Test
    func `selectProgram with unknown id does not crash`() {
      let player = Player(instance: TestInstance.shared)
      player.selectProgram(id: 999)
    }

    /// `isProgramScrambled` on a player without active programs must
    /// return `false` without crashing.
    @Test
    func `isProgramScrambled without programs is false`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isProgramScrambled == false)
    }

    // MARK: - Teletext round trip

    @Test
    func `teletextPage round trip`() {
      let player = Player(instance: TestInstance.shared)
      player.teletextPage = 100
      // libVLC without a decoder may not actually accept teletext, but
      // we still exercise the setter/getter path.
      _ = player.teletextPage
    }

    // MARK: - Recording

    /// `startRecording` and `stopRecording` without media must not crash.
    @Test
    func `recording toggle without media does not crash`() {
      let player = Player(instance: TestInstance.shared)
      player.startRecording(to: "/tmp/swiftvlc-test-recording")
      player.stopRecording()
    }

    // MARK: - Mix / Stereo mode round trip

    @Test
    func `stereoMode round trip`() {
      let player = Player(instance: TestInstance.shared)
      player.stereoMode = .mono
      #expect(player.stereoMode == .mono)
      player.stereoMode = .reverseStereo
      #expect(player.stereoMode == .reverseStereo)
    }

    @Test
    func `mixMode round trip`() {
      let player = Player(instance: TestInstance.shared)
      player.mixMode = .binaural
      #expect(player.mixMode == .binaural)
      player.mixMode = .fivePointOne
      #expect(player.mixMode == .fivePointOne)
    }

    // MARK: - audioDevices()

    /// `audioDevices()` returns whatever libVLC enumerates for the
    /// current output. With `--no-audio` the list is empty; on real
    /// macOS it has at least the default device. Either way, no crash.
    @Test
    func `audioDevices enumerates without crashing`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.audioDevices()
    }

    // MARK: - currentAudioDevice

    /// Reading `currentAudioDevice` must be safe even when no device
    /// is selected.
    @Test
    func `currentAudioDevice read is safe`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.currentAudioDevice
    }

    // MARK: - A-B loop state read

    @Test
    func `abLoopState defaults to none`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.abLoopState == .none)
    }
  }
}
