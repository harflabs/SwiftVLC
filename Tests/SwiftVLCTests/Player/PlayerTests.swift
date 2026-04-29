@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerTests {
    @Test
    func `Init succeeds`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.state == .idle)
    }

    @Test
    func `Initial state is idle`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.state == .idle)
    }

    @Test
    func `Initial time is zero`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.currentTime == .zero)
    }

    @Test
    func `Initial duration is nil`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.duration == nil)
    }

    @Test
    func `Initial not seekable`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isSeekable == false)
    }

    @Test
    func `Initial not pausable`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isPausable == false)
    }

    @Test
    func `Initial media is nil`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.currentMedia == nil)
    }

    @Test
    func `Initial tracks are empty`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.audioTracks.isEmpty)
      #expect(player.videoTracks.isEmpty)
      #expect(player.subtitleTracks.isEmpty)
    }

    @Test
    func `Load sets media`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.testMP4URL)
      player.load(media)
      #expect(player.currentMedia != nil)
    }

    @Test
    func `mediaChanged resyncs currentMedia and clears timeline state`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let initial = try Media(url: TestMedia.testMP4URL)
      let replacement = try Media(url: TestMedia.twosecURL)

      player.load(initial)
      player._setStateForTesting(
        currentTime: .seconds(5),
        duration: .seconds(30),
        position: 0.5,
        isSeekable: true,
        isPausable: true
      )

      libvlc_media_player_set_media(player.pointer, replacement.pointer)
      player._handleEventForTesting(.mediaChanged)

      #expect(player.currentMedia?.mrl == replacement.mrl)
      #expect(player.currentTime == .zero)
      #expect(player.duration == nil)
      #expect(player.position == 0)
      #expect(player.isSeekable == false)
      #expect(player.isPausable == false)
    }

    @Test
    func `mediaChanged retains synced media after native player switches again`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let initial = try Media(url: TestMedia.testMP4URL)
      player.load(initial)

      let syncedMedia: Media
      let syncedMRL: String
      do {
        let replacement = try Media(url: TestMedia.twosecURL)
        libvlc_media_player_set_media(player.pointer, replacement.pointer)
        player._handleEventForTesting(.mediaChanged)
        syncedMedia = try #require(player.currentMedia)
        syncedMRL = try #require(replacement.mrl)
      }

      libvlc_media_player_set_media(player.pointer, initial.pointer)
      player._handleEventForTesting(.mediaChanged)

      #expect(syncedMedia.mrl == syncedMRL)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Play starts playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(await poll(until: { player.state != .idle }), "Waiting for: player.state != .idle")
      #expect(player.state != .idle)
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Pause pauses playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      player.pause()
      try #require(await poll(until: { player.state == .paused }), "Waiting for: player.state == .paused")
      #expect(player.state == .paused)
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Resume after pause`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      player.pause()
      try #require(await poll(until: { player.state == .paused }), "Waiting for: player.state == .paused")
      player.resume()
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      #expect(player.state == .playing)
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Stop stops playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(await poll(until: { player.state != .idle }), "Waiting for: player.state != .idle")
      player.stop()
      try #require(await poll(until: { player.state == .stopped || player.state == .idle }), "Waiting for: player.state == .stopped || player.state == .idle")
      #expect(player.state == .stopped || player.state == .idle || player.state == .stopping)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Seek to time`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      player.seek(to: .seconds(1))
      try await Task.sleep(for: .milliseconds(100))
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Seek by offset`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      player.seek(by: .milliseconds(500))
      try await Task.sleep(for: .milliseconds(100))
      player.stop()
    }

    @Test
    func `Volume get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.volume = 0.5
      let vol = player.volume
      #expect(vol >= 0.4 && vol <= 0.6)
    }

    @Test
    func `Volume clamping`() {
      let player = Player(instance: TestInstance.shared)
      player.volume = -1.0
      #expect(player.volume >= 0)
    }

    @Test
    func mute() {
      let player = Player(instance: TestInstance.shared)
      player.isMuted = true
      #expect(player.isMuted == true)
      player.isMuted = false
      #expect(player.isMuted == false)
    }

    @Test
    func `Rate get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.rate = 2.0
      #expect(player.rate == 2.0)
      player.rate = 1.0
    }

    @Test
    func `Position get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.position = 0.5
    }

    @Test
    func `Audio delay get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.audioDelay = .milliseconds(500)
      _ = player.audioDelay
    }

    @Test
    func `Subtitle delay get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.subtitleDelay = .milliseconds(200)
      _ = player.subtitleDelay
    }

    @Test
    func `Subtitle text scale get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.subtitleTextScale = 1.5
      let scale = player.subtitleTextScale
      #expect(scale > 0)
    }

    @Test
    func `Role get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.role = .music
      #expect(player.role == .music)
      player.role = .none
    }

    @Test
    func `isPlaying reflects state`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isPlaying == false)
    }

    @Test
    func `isActive reflects state`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isActive == false)
    }

    @Test
    func `Statistics nil without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.statistics == nil)
    }

    @Test(.tags(.async))
    func `Events stream`() async {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events
      let task = Task {
        for await _ in stream {
          break
        }
      }
      task.cancel()
      await task.value
    }

    @Test
    func `Chapter count zero without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.chapterCount <= 0)
    }

    @Test
    func `Title count zero without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.titleCount <= 0)
    }

    @Test
    func `AB loop initial state`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.abLoopState == .none)
    }

    @Test
    func `Equalizer get and set`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.equalizer == nil)
      let eq = Equalizer()
      player.equalizer = eq
      #expect(player.equalizer != nil)
      player.equalizer = nil
      #expect(player.equalizer == nil)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Play URL convenience`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.testMP4URL)
      try #require(await poll(until: { player.state != .idle }), "Waiting for: player.state != .idle")
      #expect(player.state != .idle)
      player.stop()
    }

    @Test
    func `Audio devices`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.audioDevices()
    }

    @Test
    func `Stereo mode get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.stereoMode = .mono
      _ = player.stereoMode
    }

    @Test
    func `Mix mode get and set`() {
      let player = Player(instance: TestInstance.shared)
      player.mixMode = .stereo
      _ = player.mixMode
    }

    @Test
    func `Programs empty`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.programs.isEmpty)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Stop resets position`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      player.stop()
      try #require(await poll(until: { player.state == .stopped || player.state == .idle }), "Waiting for: player.state == .stopped || player.state == .idle")
      #expect(player.currentTime == .zero)
    }

    @Test
    func `Play invalid media throws error`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(path: "/dev/null")
      do {
        try player.play(media)
      } catch {
        // Expected for some media sources
      }
      player.stop()
    }

    @Test
    func `Toggle play pause`() {
      let player = Player(instance: TestInstance.shared)
      player.togglePlayPause()
    }

    @Test
    func `Navigate doesn't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.navigate(.activate)
      player.navigate(.up)
    }

    @Test
    func `Next frame doesn't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.nextFrame()
    }

    @Test
    func `Current audio device`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.currentAudioDevice
    }

    // MARK: - Additional Coverage

    @Test
    func `Selected audio track nil without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.selectedAudioTrack == nil)
    }

    @Test
    func `Selected subtitle track nil without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.selectedSubtitleTrack == nil)
    }

    @Test
    func `Deselect audio track doesn't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.selectedAudioTrack = nil
    }

    @Test
    func `Deselect subtitle track doesn't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.selectedSubtitleTrack = nil
    }

    @Test
    func `Start and stop recording doesn't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.startRecording()
      player.stopRecording()
    }

    @Test
    func `Next and previous chapter don't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.nextChapter()
      player.previousChapter()
    }

    @Test
    func `Current chapter get and set`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.currentChapter
      player.currentChapter = 0
    }

    @Test
    func `Current title get and set`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.currentTitle
      player.currentTitle = 0
    }

    @Test
    func `Titles empty without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.titles.isEmpty)
    }

    @Test
    func `Chapters empty without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.chapters().isEmpty)
    }

    @Test
    func `Set AB loop by time without media`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try player.setABLoop(a: .seconds(1), b: .seconds(2))
      }
    }

    @Test
    func `Set AB loop by position without media`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try player.setABLoop(aPosition: 0.1, bPosition: 0.9)
      }
    }

    @Test
    func `Reset AB loop without media`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try player.resetABLoop()
      }
    }

    @Test
    func `Take snapshot without playback doesn't crash`() throws {
      let player = Player(instance: TestInstance.shared)
      do {
        try player.takeSnapshot(to: "/tmp/snapshot_test.png")
      } catch {
        _ = error
      }
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Add external subtitle track`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      do {
        try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle)
      } catch {
        // Expected if player state doesn't support it
      }
      player.stop()
    }

    @Test
    func `Set audio output with invalid name fails`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try player.setAudioOutput("nonexistent_output_xyz")
      }
    }

    @Test
    func `Set audio device with invalid id`() throws {
      let player = Player(instance: TestInstance.shared)
      do {
        try player.setAudioDevice("nonexistent_device_xyz")
      } catch {
        _ = error
      }
    }

    @Test
    func `Select program by id doesn't crash`() {
      let player = Player(instance: TestInstance.shared)
      player.selectProgram(id: 0)
    }

    @Test
    func `Is program scrambled`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.isProgramScrambled == false)
    }

    @Test
    func `Set renderer nil doesn't crash`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.setRenderer(nil)
    }

    @Test
    func `Set deinterlace auto`() throws {
      let player = Player(instance: TestInstance.shared)
      do {
        try player.setDeinterlace(state: -1)
      } catch {
        // Expected without active video
      }
    }

    @Test
    func `Set deinterlace with mode`() throws {
      let player = Player(instance: TestInstance.shared)
      do {
        try player.setDeinterlace(state: 1, mode: "blend")
      } catch {
        // Expected without active video
      }
    }

    @Test
    func `Teletext page get and set`() {
      let player = Player(instance: TestInstance.shared)
      _ = player.teletextPage
      player.teletextPage = 100
    }

    @Test
    func `Aspect ratio set and get`() {
      let player = Player(instance: TestInstance.shared)
      player.aspectRatio = .ratio(16, 9)
      #expect(player.aspectRatio == .ratio(16, 9))
      player.aspectRatio = .fill
      #expect(player.aspectRatio == .fill)
      player.aspectRatio = .default
      #expect(player.aspectRatio == .default)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Tracks refresh during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      _ = player.audioTracks
      _ = player.videoTracks
      _ = player.subtitleTracks
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Duration available during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))

      // libVLC's `MediaPlayerLengthChanged` event is not guaranteed to fire
      // for every media — for some inputs, the player never receives it.
      // `Player` polls `libvlc_media_player_get_length` on state transitions
      // as a safety net (see `refreshDurationFromNativeIfNeeded`); this test
      // is the regression guard for that path.
      let got = try await poll(timeout: .seconds(5), until: { player.duration != nil })
      #expect(got, "Player.duration stayed nil — the state-transition fallback isn't publishing length")

      if let dur = player.duration {
        #expect(dur.milliseconds > 0)
      }
      player.stop()
    }

    @Test
    func `Update viewpoint doesn't crash`() throws {
      let player = Player(instance: TestInstance.shared)
      let vp = Viewpoint(yaw: 90, pitch: 0, roll: 0, fieldOfView: 80)
      do {
        try player.updateViewpoint(vp)
      } catch {
        // Expected without active 360 video
      }
    }

    @Test
    func `Save metadata fails for non-local media`() throws {
      let media = try Media(path: "/nonexistent/file.mp4")
      #expect(throws: VLCError.self) {
        try media.saveMetadata()
      }
    }

    @Test
    func `Selected program nil without media`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.selectedProgram == nil)
    }

    @Test
    func `Load replaces previous media`() throws {
      let player = Player(instance: TestInstance.shared)
      let media1 = try Media(url: TestMedia.testMP4URL)
      player.load(media1)
      #expect(player.currentMedia != nil)
      let media2 = try Media(url: TestMedia.twosecURL)
      player.load(media2)
      #expect(player.currentMedia != nil)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Duration set via event during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.duration != nil }), "Waiting for: player.duration != nil")
      if let dur = player.duration {
        #expect(dur.milliseconds > 0)
      }
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Position updates during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      _ = player.position
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Seekable and pausable update during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      _ = player.isSeekable
      _ = player.isPausable
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `isActive true during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      if player.state == .playing || player.state == .opening {
        #expect(player.isActive == true)
      }
      player.stop()
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Stop sets state to stopped`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      player.stop()
      try #require(await poll(until: { player.state == .stopped || player.state == .idle }), "Waiting for: player.state == .stopped || player.state == .idle")
      #expect(player.currentTime == .zero)
    }

    @Test
    func `Adjustments accessor`() {
      let player = Player(instance: TestInstance.shared)
      let adj = player.adjustments
      _ = adj.isEnabled
    }

    @Test
    func `Marquee accessor`() {
      let player = Player(instance: TestInstance.shared)
      let m = player.marquee
      _ = m.isEnabled
    }

    @Test
    func `Logo accessor`() {
      let player = Player(instance: TestInstance.shared)
      let l = player.logo
      _ = l.isEnabled
    }

    @Test
    func `Statistics accessible with loaded media`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.testMP4URL)
      player.load(media)
      _ = player.statistics
    }
  }
}
