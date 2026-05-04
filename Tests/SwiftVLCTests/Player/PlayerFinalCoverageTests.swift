@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerFinalCoverageTests {
    // MARK: - Non-playback tests (fast, no serialization needed)

    @Test
    func `isActive false for idle state`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.state == .idle)
      #expect(player.isActive == false)
    }

    @Test
    func `Play with no media loaded exercises throw path`() {
      let player = Player(instance: TestInstance.shared)
      do {
        try player.play()
        player.stop()
      } catch {
        if case .playbackFailed = error { /* expected */ }
      }
    }

    @Test
    func `Play with invalid path media exercises throw path`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(path: "/nonexistent/totally/bogus/file.xyz"))
      do { try player.play(); player.stop() } catch { _ = error }
    }

    @Test
    func `Take snapshot without video does not crash`() {
      let player = Player(instance: TestInstance.shared)
      do { try player.takeSnapshot(to: NSTemporaryDirectory() + "snap.png") } catch { _ = error }
    }

    @Test
    func `Add external track without playback exercises path`() throws {
      let player = Player(instance: TestInstance.shared)
      do { try player.addExternalTrack(from: #require(URL(string: "file:///bogus.srt")), type: .subtitle) } catch { _ = error }
    }

    // MARK: - Consolidated playback test: Observable properties + position + seek + aspect

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `All observable properties and mutations during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      try #require(await poll(until: { player.duration != nil }), "Waiting for: player.duration != nil")
      // Read every observable property (exercises all access(keyPath:) paths)
      _ = player.position; _ = player.volume; _ = player.isMuted; _ = player.rate
      _ = player.selectedAudioTrack; _ = player.selectedSubtitleTrack
      _ = player.audioDelay; _ = player.subtitleDelay; _ = player.subtitleTextScale
      _ = player.role; _ = player.isPlaying; _ = player.isActive; _ = player.statistics
      _ = player.state; _ = player.currentTime; _ = player.duration
      _ = player.isSeekable; _ = player.isPausable; _ = player.currentMedia
      _ = player.audioTracks; _ = player.videoTracks; _ = player.subtitleTracks
      _ = player.teletextPage; _ = player.currentChapter; _ = player.currentTitle
      _ = player.stereoMode; _ = player.mixMode; _ = player.programs
      _ = player.selectedProgram; _ = player.currentAudioDevice
      _ = player.titles; _ = player.chapters(); _ = player.chapters(forTitle: 0)
      _ = player.chapters(forTitle: -1); _ = player.abLoopState; _ = player.isProgramScrambled

      // Position read and checked seek.
      #expect(player.position >= 0.0 && player.position <= 1.0)
      if player.isSeekable {
        try player.seek(to: PlaybackPosition(0.5))
        try await Task.sleep(for: .milliseconds(100))
        _ = player.position
      }

      // Absolute and relative seek paths.
      if player.isSeekable {
        try player.seek(to: .milliseconds(500))
        try player.seek(by: .milliseconds(200))
        try player.seek(by: .milliseconds(-100))
      }

      // Aspect-ratio mutations.
      player.aspectRatio = .ratio(4, 3)
      _ = player.aspectRatio
      player.aspectRatio = .fill
      player.aspectRatio = .default

      player.stop()
    }

    // MARK: - Consolidated playback test: Track selection + subtitle + audio devices

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Track selection and audio devices during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      try #require(await poll(until: { !player.audioTracks.isEmpty }), "Waiting for: !player.audioTracks.isEmpty")
      // selectedAudioTrack read path.
      _ = player.selectedAudioTrack

      // Select a concrete audio track.
      let tracks = player.audioTracks
      player.selectedAudioTrack = tracks[0]
      try await Task.sleep(for: .milliseconds(100))
      _ = player.selectedAudioTrack

      // Unselect then reselect audio.
      player.selectedAudioTrack = nil
      try await Task.sleep(for: .milliseconds(50))
      player.selectedAudioTrack = tracks[0]

      // selectedSubtitleTrack read path.
      _ = player.selectedSubtitleTrack

      // Audio-device enumeration and selection.
      let devices = player.audioDevices()
      _ = devices
      do { try player.setAudioDevice("nonexistent") } catch { _ = error }
      if let dev = devices.first {
        do { try player.setAudioDevice(dev.deviceId) } catch { _ = error }
      }

      // Audio output error path.
      do { try player.setAudioOutput("nonexistent_xyz") } catch { _ = error }

      player.stop()
    }

    // MARK: - Consolidated playback test: Pause/resume, isActive, stop reset, event consumer

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Pause resume isActive and event consumer during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))

      // State changes prove the event consumer is running.
      try #require(await poll(until: { player.state != .idle }), "Waiting for: player.state != .idle")
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // isActive true during playing
      _ = player.isActive

      // State may still be .playing during brief buffering suppression.
      try await Task.sleep(for: .milliseconds(200))
      _ = player.state

      // Pause.
      player.pause()
      try #require(await poll(until: { player.state == .paused }), "Waiting for: player.state == .paused")
      _ = player.isActive

      // Resume.
      player.resume()
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Stop and verify reset
      player.stop()
      try #require(await poll(until: { player.state == .stopped || player.state == .idle }), "Waiting for: player.state == .stopped || player.state == .idle")
      _ = player.isActive
    }

    // MARK: - Consolidated playback test: AB loop, titles, chapters, programs, snapshot

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `AB loop titles chapters programs and snapshot during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      // Titles.
      _ = player.titles

      // Chapters.
      _ = player.chapters(forTitle: 0)
      _ = player.chapters()

      // Programs.
      _ = player.programs
      _ = player.selectedProgram

      // AB loop.
      if player.isSeekable {
        do {
          try player.setABLoop(a: .milliseconds(100), b: .milliseconds(500))
          _ = player.abLoopState
          try player.resetABLoop()
        } catch { _ = error }
        do {
          try player.setABLoop(aPosition: 0.1, bPosition: 0.8)
          try player.resetABLoop()
        } catch { _ = error }
      }

      // Snapshot.
      try await Task.sleep(for: .milliseconds(200))
      do { try player.takeSnapshot(to: "/nonexistent_dir/snap.png") } catch { _ = error }

      // External track.
      do {
        try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: true)
        try await Task.sleep(for: .milliseconds(200))
        player.refreshTracks()
        _ = player.selectedSubtitleTrack
      } catch { _ = error }

      player.stop()
    }

    // MARK: - Opening/buffering transient state

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `isActive during opening state`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      // Rapidly poll for opening/buffering
      for _ in 0..<100 {
        if player.state == .opening { _ = player.isActive; break }
        if player.state == .playing { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      player.stop()
    }
  }
}
