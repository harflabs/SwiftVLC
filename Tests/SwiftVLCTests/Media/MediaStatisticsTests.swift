@testable import SwiftVLC
import Testing

extension Integration {
  struct MediaStatisticsTests {
    @Test
    func `Nil before playback`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      #expect(media.statistics() == nil)
    }

    @Test(.tags(.mainActor, .async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    @MainActor
    func `Available during playback`() async throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.testMP4URL)
      try player.play(media)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      _ = player.statistics
      player.stop()
    }

    @Test(.tags(.mainActor, .async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    @MainActor
    func `Fields are reasonable`() async throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      if let stats = player.statistics {
        #expect(stats.readBytes >= 0)
        #expect(stats.inputBitrate >= 0)
        #expect(stats.demuxReadBytes >= 0)
      }
      player.stop()
    }

    @Test
    func equatable() {
      let _: any Equatable.Type = MediaStatistics.self
    }

    @Test
    func sendable() {
      let _: any Sendable.Type = MediaStatistics.self
    }

    @Test(.tags(.mainActor, .async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    @MainActor
    func `Statistics accessible during playback`() async throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      _ = player.statistics
      _ = player.currentMedia?.statistics()
      player.stop()
    }
  }
}
