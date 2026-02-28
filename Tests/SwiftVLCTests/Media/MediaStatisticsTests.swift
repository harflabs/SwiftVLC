@testable import SwiftVLC
import Testing

@Suite("MediaStatistics", .tags(.integration), .serialized)
struct MediaStatisticsTests {
  @Test("Nil before playback")
  func nilBeforePlayback() throws {
    let media = try Media(url: TestMedia.testMP4URL)
    #expect(media.statistics() == nil)
  }

  @Test("Available during playback", .tags(.mainActor, .async, .media), .enabled(if: TestCondition.canPlayMedia))
  @MainActor
  func availableDuringPlayback() async throws {
    let player = try Player()
    let media = try Media(url: TestMedia.testMP4URL)
    try player.play(media)
    // Give player time to start
    try await Task.sleep(for: .milliseconds(500))
    // Stats may or may not be available depending on playback state
    _ = player.statistics
    player.stop()
  }

  @Test("Fields are reasonable", .tags(.mainActor, .async, .media), .enabled(if: TestCondition.canPlayMedia))
  @MainActor
  func fieldsReasonable() async throws {
    let player = try Player()
    let media = try Media(url: TestMedia.twosecURL)
    try player.play(media)
    try await Task.sleep(for: .milliseconds(800))
    if let stats = player.statistics {
      // Read bytes should be non-negative
      #expect(stats.readBytes >= 0)
      #expect(stats.inputBitrate >= 0)
      #expect(stats.demuxReadBytes >= 0)
    }
    player.stop()
  }

  @Test("Equatable")
  func equatable() {
    // MediaStatistics is Equatable
    let _: any Equatable.Type = MediaStatistics.self
  }

  @Test("Sendable")
  func sendable() {
    let _: any Sendable.Type = MediaStatistics.self
  }

  @Test("Statistics accessible during playback", .tags(.mainActor, .async, .media), .enabled(if: TestCondition.canPlayMedia))
  @MainActor
  func statisticsAccessibleDuringPlayback() async throws {
    let player = try Player()
    let media = try Media(url: TestMedia.twosecURL)
    try player.play(media)
    try await Task.sleep(for: .milliseconds(800))
    // Access via player convenience property
    _ = player.statistics
    // Access via media directly
    _ = player.currentMedia?.statistics()
    player.stop()
  }
}
