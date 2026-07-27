@testable import SwiftVLC
import Foundation
import Testing

/// `recast(to:)` must report whether the replacement session actually settled.
///
/// Recasting tears down the live session and rebuilds it on another renderer,
/// then restores position, track selection and paused state. Returning `Void`
/// made "playing with everything reapplied" indistinguishable from "never
/// reached playback", "failed asynchronously", "the caller gave up", and
/// "something else took the session over" — while the restore steps kept
/// mutating regardless.
///
/// CI cannot drive a real session to `.playing`
/// (`TestCondition.canPlayMedia`), so the wait's outcome mapping is exercised
/// against synthetic transition streams.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerRecastOutcomeTests {
    // MARK: - Playback wait

    /// Reaching playback is the only arrival.
    @Test
    func `Reaching playing settles the wait`() async {
      let transitions = Self.stateStream([.opening, .buffering, .playing])

      let result = await Player.awaitPlaying(on: transitions, timeout: .seconds(5))

      #expect(result == .playing)
    }

    /// The core of the fix: an asynchronous failure must be reported as a
    /// failure, not silently accepted as arrival the way the old
    /// `state == .playing || state == .error` break did.
    @Test
    func `An error is reported as failed rather than arrival`() async {
      let transitions = Self.stateStream([.opening, .error])

      let result = await Player.awaitPlaying(on: transitions, timeout: .seconds(5))

      #expect(result == .failed)
      #expect(result != .playing)
    }

    /// A session that never settles is bounded and says so.
    @Test
    func `A session that never reaches playback times out`() async {
      let transitions = Self.stateStream([.opening, .buffering])

      let result = await Player.awaitPlaying(
        on: transitions,
        timeout: .milliseconds(50)
      )

      #expect(result == .timedOut)
    }

    /// Nothing at all still terminates.
    @Test
    func `An empty transition stream times out`() async {
      let result = await Player.awaitPlaying(
        on: Self.stateStream([]),
        timeout: .milliseconds(50)
      )

      #expect(result == .timedOut)
    }

    /// Playing wins over a later error in the same stream.
    @Test
    func `Playing before an error settles`() async {
      let transitions = Self.stateStream([.playing, .error])

      let result = await Player.awaitPlaying(on: transitions, timeout: .seconds(5))

      #expect(result == .playing)
    }

    // MARK: - Outcome surface

    /// Only `settled` reads as success, so a new case cannot silently pass a
    /// caller's success check.
    @Test
    func `Only settled is a settled outcome`() {
      #expect(RecastOutcome.settled.isSettled)
      for outcome: RecastOutcome in [.failed, .timedOut, .cancelled, .superseded] {
        #expect(!outcome.isSettled, "\(outcome) must not read as settled")
      }
    }

    // MARK: - Supersession

    /// Loading new media takes the session over, so an in-flight recast must
    /// see that it no longer owns it.
    @Test
    func `Loading media supersedes the current session generation`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let before = player.sessionGeneration

      try player.load(Media(url: TestMedia.silenceURL))

      #expect(
        player.sessionGeneration != before,
        "a media load left the session generation unchanged, so a recast would keep restoring onto it"
      )
    }

    /// The replacement branch of `play(_:)` also swaps the media, so it must
    /// supersede too.
    @Test
    func `An active replacement supersedes the current session generation`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      player._setStateForTesting(state: .playing)
      let before = player.sessionGeneration

      try? player.play(Media(url: TestMedia.twosecURL))

      #expect(player.sessionGeneration != before)
    }

    /// A recast on a player that never started is a plain renderer change and
    /// settles immediately — no session exists to restore.
    @Test
    func `Recasting a never-played player settles immediately`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let outcome = try await player.recast(to: nil)

      #expect(outcome == .settled)
    }

    /// Builds a finite stream of states, finishing after the last one.
    private static func stateStream(_ states: [PlayerState]) -> AsyncStream<PlayerState> {
      AsyncStream { continuation in
        for state in states {
          continuation.yield(state)
        }
        continuation.finish()
      }
    }
  }
}
