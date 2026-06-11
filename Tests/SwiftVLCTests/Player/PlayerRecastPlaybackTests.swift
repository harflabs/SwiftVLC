@testable import SwiftVLC
import Testing

/// Integration coverage for `recast(to:)`'s replay body on an active
/// session: switching renderer mid-playback replaces the native handle
/// and restarts the current media in place. These drive real playback,
/// so they gate on `TestCondition.canPlayMedia` and skip on CI (runners
/// cannot decode media); the session-free recast paths and the
/// track-matching logic are covered by `PlayerCarryOverTests` and
/// `PlayerRecastTrackMatchTests`.
extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerRecastPlaybackTests {
    /// `recast(to: nil)` on a playing session replaces the handle (libVLC
    /// only applies renderer selection before a handle's first play) and
    /// resumes local playback on the new session.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `recast on an active session replaces the handle and resumes`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      let oldPointer = player.pointer
      try await player.recast(to: nil)

      #expect(
        player.pointer != oldPointer,
        "recast did not replace the native handle of an active session"
      )
      try #require(
        await poll(until: { player.state == .playing }),
        "playback did not resume on the new session after recast"
      )
    }

    /// While a session is live, `programs` reflects the media's program
    /// list and `selectedProgram` is one of them — the populated getter
    /// paths a media-less player never reaches.
    @Test(.timeLimit(.minutes(1)), .enabled(if: TestCondition.canPlayMedia))
    func `programs and selectedProgram reflect the live session`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { !player.programs.isEmpty }),
        "Waiting for: the media's default program to appear"
      )

      let programs = player.programs
      #expect(!player.isProgramScrambled, "clear media reported as scrambled")
      if let selected = player.selectedProgram {
        #expect(
          programs.contains { $0.id == selected.id },
          "selectedProgram \(selected.id) is not in the program list"
        )
      }
    }
  }
}
