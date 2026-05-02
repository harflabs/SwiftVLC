@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerSubtitleTests {
    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `external subtitle selection remains selected after aspect ratio changes`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .playing }),
        "Waiting for playback"
      )
      try player.addExternalTrack(from: TestMedia.subtitleURL, type: .subtitle, select: true)
      try #require(
        await poll(timeout: .seconds(10), until: { !player.subtitleTracks.isEmpty }),
        "Waiting for subtitle tracks"
      )

      let subtitle = try #require(player.subtitleTracks.first)
      player.selectedSubtitleTrack = subtitle

      try #require(
        await poll(timeout: .seconds(10), until: { player.selectedSubtitleTrack?.id == subtitle.id }),
        "Waiting for selected subtitle track"
      )

      for ratio: AspectRatio in [.ratio(4, 3), .fill, .ratio(16, 9), .default] {
        player.aspectRatio = ratio
        try await Task.sleep(for: .milliseconds(100))
        try #require(
          player.selectedSubtitleTrack?.id == subtitle.id,
          "Subtitle selection should survive aspect ratio change to \(ratio)"
        )
      }

      player.stop()
    }
  }
}
