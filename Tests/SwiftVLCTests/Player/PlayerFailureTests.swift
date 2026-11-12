@testable import SwiftVLC
import Foundation
import Testing

/// libVLC opens media asynchronously, so `play()` returns before an
/// unreachable source can fail, and `state` only passes through `.error` on
/// its way to `.stopped`. `Player.failure` is what remains observable.
extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerFailureTests {
    @Test(.timeLimit(.minutes(1)))
    func `A session that fails to open leaves its failure observable`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      #expect(player.failure == nil)

      try player.play(Media(path: "/nonexistent/swiftvlc-\(UUID().uuidString).mp4"))
      try #require(
        await poll(timeout: .seconds(10)) { player.state == .stopped },
        "Waiting for: the unopenable media to settle stopped"
      )
      #expect(player.failure == .source)
      #expect(!player.didReachEnd)

      try player.play(Media(url: TestMedia.twosecURL))
      #expect(player.failure == nil, "the next session inherited the previous failure")
      try #require(
        await poll(timeout: .seconds(15)) { player.didReachEnd },
        "Waiting for: the good media to play out"
      )
      #expect(player.failure == nil)
      await player.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func `Retrying and loading both clear the failure`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let missing = "/nonexistent/swiftvlc-\(UUID().uuidString).mp4"

      try player.play(Media(path: missing))
      try #require(await poll(timeout: .seconds(10)) { player.state == .stopped })
      try #require(player.failure == .source)

      // A bare retry starts a new session, whose own failure is reported again.
      try player.play()
      #expect(player.failure == nil)
      try #require(await poll(timeout: .seconds(10)) { player.failure == .source })
      try #require(await poll(timeout: .seconds(10)) { player.state == .stopped })

      try player.load(Media(url: TestMedia.twosecURL))
      #expect(player.failure == nil)
      await player.shutdown()
    }

    /// A stop the app asked for is not a failure, whatever the session was
    /// doing when it arrived.
    @Test(.timeLimit(.minutes(1)))
    func `A requested stop reports no failure`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      await player.stopAndWait()
      #expect(player.failure == nil)
      await player.shutdown()
    }
  }
}
