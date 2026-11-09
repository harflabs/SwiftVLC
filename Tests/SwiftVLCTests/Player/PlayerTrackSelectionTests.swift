@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// Audio and subtitle selection, external tracks, and delays against real
/// libVLC playback of `Fixtures/tracks`.
///
/// The instance uses dummy outputs with software decoding, so the suite runs
/// headless. libVLC applies selection commands from one ordered input queue;
/// tests that assert something did *not* happen wait for a later command in
/// that queue to land first instead of sleeping.
extension Integration {
  @Suite(.tags(.mainActor, .media, .async))
  @MainActor struct PlayerTrackSelectionTests {
    // MARK: - Selection is ordered and sticky (T2)

    @Test
    func `A subtitle selection undone at once stays off`() async throws {
      let player = try await playMultitrackMKV()
      let arabic = try #require(player.subtitleTracks.first { $0.language == "ara" })

      player.selectedSubtitleTrack = arabic
      player.selectedSubtitleTrack = nil
      try await drainSelectionQueue(of: player, switching: .audio)

      #expect(player.selectedSubtitleTrack == nil)
      await player.shutdown()
    }

    @Test
    func `An audio selection undone at once stays off`() async throws {
      let player = try await playMultitrackMKV()
      let arabic = try #require(player.audioTracks.first { $0.language == "ara" })

      player.selectedAudioTrack = arabic
      player.selectedAudioTrack = nil
      try await drainSelectionQueue(of: player, switching: .subtitle)

      #expect(player.selectedAudioTrack == nil)
      await player.shutdown()
    }

    @Test
    func `Deselecting then selecting at once selects the track`() async throws {
      let player = try await playMultitrackMKV()
      let english = try #require(player.subtitleTracks.first { $0.language == "eng" })

      player.selectedSubtitleTrack = nil
      player.selectedSubtitleTrack = english

      #expect(try await poll(timeout: .seconds(10)) {
        player.selectedSubtitleTrack?.id == english.id
      })
      await player.shutdown()
    }

    @Test
    func `A track of another type is ignored`() async throws {
      let player = try await playMultitrackMKV()
      let english = try #require(player.subtitleTracks.first { $0.language == "eng" })

      player.selectedAudioTrack = english
      try await drainSelectionQueue(of: player, switching: .audio)

      #expect(player.selectedSubtitleTrack == nil)
      #expect(player.selectedAudioTrack?.type == .audio)
      await player.shutdown()
    }

    // MARK: - Unstable adaptive ids (T1)

    @Test
    func `Adaptive tracks report unstable ids and container tracks stable ones`() async throws {
      let hls = try await playMultitrackHLS()
      #expect(!hls.audioTracks.isEmpty && !hls.subtitleTracks.isEmpty)
      #expect((hls.audioTracks + hls.subtitleTracks).allSatisfy { !$0.isIDStable })
      await hls.shutdown()

      let mkv = try await playMultitrackMKV()
      let containerIDsAreStable = (mkv.audioTracks + mkv.subtitleTracks).allSatisfy(\.isIDStable)
      #expect(containerIDsAreStable)
      await mkv.shutdown()
    }

    @Test
    func `A subtitle captured before its id was recreated still selects`() async throws {
      let player = try await playMultitrackHLS()
      player.selectedSubtitleTrack = player.subtitleTracks.first
      try #require(await poll(timeout: .seconds(10)) { player.selectedSubtitleTrack != nil })
      let captured = try #require(player.selectedSubtitleTrack)

      // Selecting a rendition the demuxer has not parked yet keeps its id;
      // a seek recreates the selected track either way.
      try player.seek(to: .seconds(1))
      try #require(
        await poll(timeout: .seconds(10)) {
          player.selectedSubtitleTrack.map { $0.id != captured.id } == true
        },
        "a seek recreates the selected adaptive track under a new id"
      )
      player.selectedSubtitleTrack = nil
      try #require(await poll(timeout: .seconds(10)) { player.selectedSubtitleTrack == nil })

      player.selectedSubtitleTrack = captured

      #expect(try await poll(timeout: .seconds(10)) {
        player.selectedSubtitleTrack?.language == captured.language
      })
      await player.shutdown()
    }

    @Test
    func `An audio track captured before a seek still selects`() async throws {
      let player = try await playMultitrackHLS()
      let arabic = try #require(player.audioTracks.first { $0.language == "ara" })
      let english = try #require(player.audioTracks.first { $0.language == "eng" })
      player.selectedAudioTrack = arabic
      try #require(await poll(timeout: .seconds(10)) {
        player.selectedAudioTrack?.language == "ara"
      })
      let captured = try #require(player.selectedAudioTrack)

      try player.seek(to: .seconds(1))
      try #require(
        await poll(timeout: .seconds(10)) {
          player.selectedAudioTrack.map { $0.id != captured.id && $0.language == "ara" } == true
        },
        "a seek recreates the selected adaptive track under a new id"
      )
      player.selectedAudioTrack = english
      try #require(await poll(timeout: .seconds(10)) {
        player.selectedAudioTrack?.language == "eng"
      })

      player.selectedAudioTrack = captured

      #expect(try await poll(timeout: .seconds(10)) {
        player.selectedAudioTrack?.language == "ara"
      })
      await player.shutdown()
    }

    // MARK: - External tracks (T3)

    @Test
    func `An external subtitle added with select replaces an explicit selection`() async throws {
      let player = try await playMultitrackMKV()
      let embeddedIDs = Set(player.subtitleTracks.map(\.id))
      let english = try #require(player.subtitleTracks.first { $0.language == "eng" })
      player.selectedSubtitleTrack = english
      try #require(await poll(timeout: .seconds(10)) {
        player.selectedSubtitleTrack?.id == english.id
      })

      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: true)

      #expect(try await poll(timeout: .seconds(10)) {
        player.selectedSubtitleTrack.map { !embeddedIDs.contains($0.id) } == true
      })
      await player.shutdown()
    }

    @Test
    func `Adding an attached external file again keeps one copy`() async throws {
      let player = try await playMultitrackMKV()
      let embeddedCount = player.subtitleTracks.count
      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: false)
      try #require(await poll(timeout: .seconds(10)) {
        player.subtitleTracks.count == embeddedCount + 1
      })

      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: false)
      // Slaves load in order, so this one appearing means the repeat was
      // processed too.
      try player.addExternalTrack(from: TestMedia.automaticSRTURL, type: .subtitle, select: false)
      try #require(await poll(timeout: .seconds(10)) {
        player.subtitleTracks.count >= embeddedCount + 2
      })
      player.refreshTracks()

      let ids = player.subtitleTracks.map(\.id)
      #expect(ids.count == embeddedCount + 2)
      #expect(Set(ids).count == ids.count)
      await player.shutdown()
    }

    @Test
    func `Adding an attached external file with select selects it`() async throws {
      let player = try await playMultitrackMKV()
      let embeddedIDs = Set(player.subtitleTracks.map(\.id))
      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: false)
      try #require(await poll(timeout: .seconds(10)) {
        player.subtitleTracks.count == embeddedIDs.count + 1
      })
      let external = try #require(player.subtitleTracks.first { !embeddedIDs.contains($0.id) })
      #expect(external.isIDStable)

      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: true)

      #expect(try await poll(timeout: .seconds(10)) {
        player.selectedSubtitleTrack?.id == external.id
      })
      #expect(player.subtitleTracks.count == embeddedIDs.count + 1)
      await player.shutdown()
    }

    @Test
    func `A newer selection cancels a pending external select`() async throws {
      let player = try await playMultitrackMKV()
      let embeddedCount = player.subtitleTracks.count
      let arabic = try #require(player.subtitleTracks.first { $0.language == "ara" })

      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: true)
      player.selectedSubtitleTrack = arabic
      try #require(await poll(timeout: .seconds(10)) {
        player.subtitleTracks.count == embeddedCount + 1
      })
      try await drainSelectionQueue(of: player, switching: .audio)

      #expect(player.selectedSubtitleTrack?.id == arabic.id)
      await player.shutdown()
    }

    // MARK: - Delays (T4)

    @Test
    func `Delays survive stop and replay`() async throws {
      let player = try await playMultitrackMKV()
      try player.setAudioDelay(.milliseconds(-250))
      try player.setSubtitleDelay(.milliseconds(400))
      #expect(nativeDelays(of: player) == Delays(audio: -250_000, subtitle: 400_000))

      await player.stopAndWait()
      #expect(player.audioDelay == .milliseconds(-250))
      #expect(player.subtitleDelay == .milliseconds(400))

      try player.setSubtitleDelay(.milliseconds(300))
      #expect(player.subtitleDelay == .milliseconds(300))

      try player.play()
      try #require(await poll(timeout: .seconds(10)) { player.state == .playing })
      #expect(try await poll(timeout: .seconds(5)) {
        nativeDelays(of: player) == Delays(audio: -250_000, subtitle: 300_000)
      })
      #expect(player.audioDelay == .milliseconds(-250))
      #expect(player.subtitleDelay == .milliseconds(300))
      await player.shutdown()
    }

    @Test
    func `Delays set during playback carry into the next media`() async throws {
      let player = try await playMultitrackMKV()
      try player.setAudioDelay(.milliseconds(120))
      try player.setSubtitleDelay(.milliseconds(-80))

      try player.play(Media(url: TestMedia.multitrackHLSURL))
      try #require(await poll(timeout: .seconds(10)) {
        player.state == .playing && !player.audioTracks.isEmpty
      })

      #expect(try await poll(timeout: .seconds(5)) {
        nativeDelays(of: player) == Delays(audio: 120_000, subtitle: -80000)
      })
      await player.shutdown()
    }

    @Test
    func `Delays set while stopped carry into the next media`() async throws {
      let player = try await playMultitrackMKV()
      await player.stopAndWait()
      try player.setAudioDelay(.milliseconds(120))
      try player.setSubtitleDelay(.milliseconds(-80))

      try player.play(Media(url: TestMedia.multitrackHLSURL))
      try #require(await poll(timeout: .seconds(10)) {
        player.state == .playing && !player.audioTracks.isEmpty
      })

      #expect(try await poll(timeout: .seconds(5)) {
        nativeDelays(of: player) == Delays(audio: 120_000, subtitle: -80000)
      })
      #expect(player.audioDelay == .milliseconds(120))
      #expect(player.subtitleDelay == .milliseconds(-80))
      await player.shutdown()
    }

    // MARK: - Helpers

    private struct Delays: Equatable {
      let audio: Int64
      let subtitle: Int64
    }

    private func nativeDelays(of player: Player) -> Delays {
      Delays(
        audio: libvlc_audio_get_delay(player.pointer),
        subtitle: libvlc_video_get_spu_delay(player.pointer)
      )
    }

    /// Dummy outputs and software decoding: no window server, audio device,
    /// or hardware decoder is needed, and subtitle decoders get the video
    /// output they wait for.
    private func makePlayer() throws -> Player {
      try Player(instance: VLCInstance(
        arguments: VLCInstance.defaultArguments
          + ["--vout=dummy", "--aout=dummy", "--no-hw-dec", "--quiet"]
      ))
    }

    private func playMultitrackMKV() async throws -> Player {
      let player = try makePlayer()
      try player.play(Media(url: TestMedia.multitrackMKVURL))
      try #require(
        await poll(timeout: .seconds(10)) {
          player.state == .playing
            && player.audioTracks.count == 2
            && player.subtitleTracks.count == 2
        },
        "Waiting for the MKV tracks"
      )
      try #require(player.selectedSubtitleTrack == nil, "no subtitle is a default")
      return player
    }

    private func playMultitrackHLS() async throws -> Player {
      let player = try makePlayer()
      try player.play(Media(url: TestMedia.multitrackHLSURL))
      try #require(
        await poll(timeout: .seconds(10)) {
          player.state == .playing
            && player.isSeekable
            && player.audioTracks.count == 2
            && player.subtitleTracks.count == 1
            && player.selectedAudioTrack != nil
        },
        "Waiting for the HLS renditions"
      )
      return player
    }

    /// Returns once libVLC has applied every selection queued so far.
    ///
    /// Switching the other type's track rides the same ordered input queue,
    /// so observing that switch proves the earlier commands were processed.
    private func drainSelectionQueue(of player: Player, switching type: TrackType) async throws {
      let tracks = type == .audio ? player.audioTracks : player.subtitleTracks
      let target = try #require(tracks.first { !$0.isSelected })
      if type == .audio {
        player.selectedAudioTrack = target
      } else {
        player.selectedSubtitleTrack = target
      }
      try #require(
        await poll(timeout: .seconds(10)) {
          let selected = type == .audio ? player.selectedAudioTrack : player.selectedSubtitleTrack
          return selected?.id == target.id
        },
        "Waiting for the \(type) barrier selection"
      )
      player.refreshTracks()
    }
  }
}
