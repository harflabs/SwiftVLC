@testable import SwiftVLC
import Foundation
import Testing

/// Integration guards for `LogNoiseFilter` — complement to the unit tests
/// that pin the rules in isolation. These verify that under real libVLC
/// behavior the filter doesn't silence log classes it shouldn't, and does
/// silence the ones it should.
///
/// Tagged `.integration` because they spin up real `Player` / `VLCInstance`
/// and consume `logStream`; the unit tests in `LogNoiseFilterTests` cover
/// the pure reclassification logic without libVLC.
@Suite(.tags(.integration, .async), .timeLimit(.minutes(1)))
struct LogNoiseFilterIntegrationTests {
  /// An unreachable media URL triggers libVLC's access/demux errors. None of
  /// those messages match any noise rule, so at least one `.error`-level
  /// entry must reach a subscriber. If this test starts failing, the filter
  /// has over-reached — a rule matched a message it shouldn't.
  @Test(.enabled(if: TestCondition.canPlayMedia))
  func `Genuine errors still reach .error subscribers (filter does not over-reach)`() async throws {
    let stream = VLCInstance.shared.logStream(minimumLevel: .error)

    let errorSeen = Task { () -> Bool in
      for await entry in stream {
        if entry.level == .error { return true }
      }
      return false
    }

    // Small delay so the callback is installed before we trigger errors.
    try await Task.sleep(for: .milliseconds(50))

    let player = await Player()
    try? await player.play(url: URL(fileURLWithPath: "/definitely/does/not/exist/\(UUID().uuidString).mp4"))

    let deadline = ContinuousClock.now + .seconds(10)
    while !errorSeen.isCancelled && ContinuousClock.now < deadline {
      if await errorSeen.value { break }
      try await Task.sleep(for: .milliseconds(100))
    }

    errorSeen.cancel()
    await player.stop()

    let saw = await errorSeen.value
    #expect(saw, "Expected at least one .error-level log entry for an unreachable media URL")
  }
}
