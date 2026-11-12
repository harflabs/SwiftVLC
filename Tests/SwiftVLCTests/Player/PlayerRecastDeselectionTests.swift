@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  /// A recast rebuilds the session on a fresh native handle, which starts
  /// again from the stream's default track selection. A type the user had
  /// turned off must stay off: on a Chromecast a reappearing subtitle is
  /// burned into a full video transcode nobody asked for.
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerRecastDeselectionTests {
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `recast keeps audio turned off`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.multitrackMKVURL)
      try #require(
        await poll(until: { player.state == .playing && player.selectedAudioTrack != nil }),
        "Waiting for: the default audio track to be selected"
      )

      player.selectedAudioTrack = nil
      try #require(
        await poll(until: { player.selectedAudioTrack == nil }),
        "Waiting for: audio to turn off before the recast"
      )

      let outcome = try await player.recastAndWaitForOutcome(to: nil)
      try #require(outcome == .settled, "recast did not settle: \(outcome)")

      try await Self.expectStaysDeselected(player, type: .audio)
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `recast keeps subtitles turned off`() async throws {
      let media = try Self.makeDefaultSubtitleVariant()
      defer { try? FileManager.default.removeItem(at: media) }
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: media)
      try #require(
        await poll(until: { player.state == .playing && player.selectedSubtitleTrack != nil }),
        "Waiting for: the default subtitle track to be selected"
      )

      player.selectedSubtitleTrack = nil
      try #require(
        await poll(until: { player.selectedSubtitleTrack == nil }),
        "Waiting for: subtitles to turn off before the recast"
      )

      let outcome = try await player.recastAndWaitForOutcome(to: nil)
      try #require(outcome == .settled, "recast did not settle: \(outcome)")

      try await Self.expectStaysDeselected(player, type: .subtitle)
      #expect(player.selectedAudioTrack != nil, "audio was never turned off")
    }

    /// A type that had nothing selected only because the session had not
    /// listed its tracks yet carries no intent, so the default must stand.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `recast leaves the default selection alone when nothing was turned off`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.multitrackMKVURL)
      try #require(
        await poll(until: { player.state == .playing && player.selectedAudioTrack != nil }),
        "Waiting for: the default audio track to be selected"
      )

      let outcome = try await player.recastAndWaitForOutcome(to: nil)
      try #require(outcome == .settled, "recast did not settle: \(outcome)")

      try #require(
        await poll(until: { player.selectedAudioTrack != nil }),
        "the replacement session lost its default audio selection"
      )
    }

    /// A copy of the multitrack fixture whose first subtitle track is flagged
    /// as the default, which is what makes libVLC select a subtitle on its own
    /// at the start of every session.
    ///
    /// The fixture stores `FlagDefault = 0` (`88 81 00`) once per track, in
    /// track order, ahead of the first cluster. Flipping the fourth entry
    /// (track 4, the English subtitle) avoids checking in a second container
    /// that differs by one byte. The test's first `#require` proves the flip
    /// took effect.
    private static func makeDefaultSubtitleVariant() throws -> URL {
      var bytes = try [UInt8](Data(contentsOf: TestMedia.multitrackMKVURL))
      let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
      let header = try #require(
        bytes.indices.dropLast(3).first { Array(bytes[$0..<$0 + 4]) == clusterID }
      )
      let clearedDefaultFlags = (0..<header - 2).filter {
        bytes[$0] == 0x88 && bytes[$0 + 1] == 0x81 && bytes[$0 + 2] == 0x00
      }
      try #require(
        clearedDefaultFlags.count == 5,
        "multitrack.mkv no longer stores one cleared default flag per track"
      )
      bytes[clearedDefaultFlags[3] + 2] = 0x01

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftvlc-default-subtitle-\(UUID().uuidString).mkv")
      try Data(bytes).write(to: url)
      return url
    }

    private static func expectStaysDeselected(
      _ player: Player,
      type: TrackType
    )
      async throws {
      func tracks() -> [Track] {
        type == .audio ? player.audioTracks : player.subtitleTracks
      }
      try #require(
        await poll(until: { !tracks().isEmpty }),
        "Waiting for: the replacement session to list its \(type) tracks"
      )
      // The default selection, if libVLC were going to make one, arrives with
      // or just after the track list. Watch past that point.
      let reselected = try await poll(timeout: .seconds(1), until: {
        tracks().contains(where: \.isSelected)
      })
      #expect(!reselected, "the replacement session re-selected a \(type) track")
    }
  }
}
