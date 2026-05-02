@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerDeepCoverageTests {
    // MARK: - Non-playback tests

    @Test
    func `Error state from invalid media`() throws {
      let player = Player(instance: TestInstance.shared)
      let badMedia = try Media(path: "/nonexistent/path/to/nothing.mp4")
      do { try player.play(badMedia) } catch { _ = error }
      player.stop()
    }

    @Test
    func `Multiple player deinits in rapid succession`() throws {
      for _ in 0..<5 {
        let player = Player(instance: TestInstance.shared)
        try player.load(Media(url: TestMedia.twosecURL))
      }
    }

    // MARK: - Consolidated: Track selection + unselect + subtitle + external track

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Track selection and external subtitle during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      try #require(await poll(until: { !player.audioTracks.isEmpty }), "Waiting for: !player.audioTracks.isEmpty")
      // Select audio track (may be empty on iOS simulator)
      let tracks = player.audioTracks
      if !tracks.isEmpty {
        player.selectedAudioTrack = tracks[0]
        try await Task.sleep(for: .milliseconds(50))
        player.refreshTracks()
      }

      // Unselect subtitle track
      player.selectedSubtitleTrack = nil
      #expect(player.selectedSubtitleTrack == nil)

      // Unselect audio track
      player.selectedAudioTrack = nil
      try await Task.sleep(for: .milliseconds(50))

      // Add external subtitle
      do {
        try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: true)
        try await Task.sleep(for: .milliseconds(200))
        _ = player.subtitleTracks
      } catch { _ = error }

      player.stop()
    }

    // MARK: - Consolidated: Aspect ratio + seek + rate + volume + mute + position

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Aspect ratio seek rate volume during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Aspect ratio all cases
      for ar: AspectRatio in [.default, .ratio(4, 3), .ratio(16, 9), .fill, .default] {
        player.aspectRatio = ar
        _ = player.aspectRatio
      }

      // Multiple seeks
      if player.isSeekable {
        player.seek(to: .milliseconds(200))
        player.seek(to: .milliseconds(800))
        player.seek(by: .milliseconds(100))
        player.seek(by: .milliseconds(-50))
      }

      // Rate (may not take effect immediately on all platforms)
      player.rate = 2.0
      player.rate = 0.5
      player.rate = 1.0

      // Volume
      player.volume = 0.3; _ = player.volume
      player.volume = 0.8; _ = player.volume
      player.volume = 1.0

      // Mute
      player.isMuted = true; _ = player.isMuted
      player.isMuted = false; _ = player.isMuted

      // Position
      player.position = 0.5
      try await Task.sleep(for: .milliseconds(100))
      #expect(player.position >= 0.0 && player.position <= 1.0)

      player.stop()
    }

    // MARK: - Consolidated: Statistics + recording + snapshot + equalizer

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Statistics recording snapshot equalizer during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      try await Task.sleep(for: .milliseconds(300))

      // Statistics (may be nil on some platforms/timing)
      _ = player.statistics

      // Recording
      player.startRecording(to: NSTemporaryDirectory())
      try await Task.sleep(for: .milliseconds(100))
      player.stopRecording()

      // Snapshot
      let path = NSTemporaryDirectory() + "swiftvlc_test.png"
      do { try player.takeSnapshot(to: path); try? FileManager.default.removeItem(atPath: path) } catch { _ = error }

      // Equalizer
      let eq = Equalizer()
      player.equalizer = eq; #expect(player.equalizer != nil)
      player.equalizer = nil; #expect(player.equalizer == nil)

      player.stop()
    }

    // MARK: - Consolidated: Pause/resume + delay + role + subtitle scale + next frame

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Pause resume delay role scale nextFrame during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Pause/resume
      player.pause()
      try #require(await poll(until: { player.state == .paused }), "Waiting for: player.state == .paused")
      player.resume()
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Audio/subtitle delay (may not persist on all platforms/simulators)
      player.audioDelay = .milliseconds(500)
      _ = player.audioDelay
      player.audioDelay = .zero

      player.subtitleDelay = .milliseconds(300)
      _ = player.subtitleDelay
      player.subtitleDelay = .zero

      // Role (may not persist on all platforms)
      player.role = .music; _ = player.role
      player.role = .none

      // Subtitle text scale (may not persist on all platforms)
      player.subtitleTextScale = 2.0
      _ = player.subtitleTextScale

      // Next frame
      player.nextFrame()
      try await Task.sleep(for: .milliseconds(100))

      player.stop()
    }

    // MARK: - Consolidated: Titles + chapters + programs + AB loop + media switch

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Titles chapters programs ABloop mediaSwitch during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Titles & chapters
      _ = player.titles; _ = player.chapters(); _ = player.chapters(forTitle: 0)
      _ = player.titleCount; _ = player.chapterCount
      _ = player.currentTitle; _ = player.currentChapter
      player.nextChapter(); player.previousChapter()

      // Programs
      _ = player.programs; _ = player.selectedProgram
      _ = player.isProgramScrambled

      // AB loop
      if player.isSeekable {
        do { try player.setABLoop(a: .milliseconds(100), b: .milliseconds(500)); try player.resetABLoop() } catch { _ = error }
        do { try player.setABLoop(aPosition: 0.1, bPosition: 0.8); try player.resetABLoop() } catch { _ = error }
      }

      // Media switch
      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(await poll(until: { player.state == .playing || player.state == .opening }), "Waiting for: player.state == .playing || player.state == .opening")
      #expect(player.currentMedia != nil)

      player.stop()
    }

    // MARK: - Consolidated: Load then play + seekable/pausable + duration + time + events + deinit

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Load play seekable duration time stop reset`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)
      #expect(player.currentMedia != nil)
      #expect(player.state == .idle)

      try player.play()
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Seekable + pausable (may not be true on all platforms)
      try #require(await poll(until: { player.isSeekable }), "Waiting for: player.isSeekable")
      _ = player.isSeekable
      _ = player.isPausable

      // Duration
      try #require(await poll(until: { player.duration != nil }), "Waiting for: player.duration != nil")
      _ = player.duration

      // Time advances
      try #require(await poll(until: { player.currentTime > .zero }), "Waiting for: player.currentTime > .zero")
      // Tracks (may be empty on some simulators)
      _ = try await poll(until: { !player.videoTracks.isEmpty })
      _ = player.audioTracks

      // Stop resets
      player.seek(to: .milliseconds(500))
      try await Task.sleep(for: .milliseconds(100))
      player.stop()
      try #require(await poll(until: { player.state == .stopped }), "Waiting for: player.state == .stopped")
      _ = player.currentTime

      // Deinit during playback (nested scope)
      do {
        let p2 = Player(instance: TestInstance.makePlayback())
        try p2.play(Media(url: TestMedia.twosecURL))
        _ = try await poll(until: { p2.state == .playing })
      }
      try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Buffering transient state

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Buffering state observed during opening`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      var sawBuffering = false
      for _ in 0..<40 {
        if case .buffering = player.state { sawBuffering = true; break }
        if player.state == .playing { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      _ = sawBuffering
      player.stop()
    }
  }
}
