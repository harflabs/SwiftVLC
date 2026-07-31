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

      let result = await Player.awaitPlaying(on: transitions, atLeast: PlaybackGeneration(1), timeout: .seconds(5))

      #expect(result == .playing)
    }

    /// The core of the fix: an asynchronous failure must be reported as a
    /// failure, not silently accepted as arrival the way the old
    /// `state == .playing || state == .error` break did.
    @Test
    func `An error is reported as failed rather than arrival`() async {
      let transitions = Self.stateStream([.opening, .error])

      let result = await Player.awaitPlaying(on: transitions, atLeast: PlaybackGeneration(1), timeout: .seconds(5))

      #expect(result == .failed)
      #expect(result != .playing)
    }

    /// A session that never settles is bounded and says so.
    @Test
    func `A session that never reaches playback times out`() async {
      let transitions = Self.stateStream([.opening, .buffering])

      let result = await Player.awaitPlaying(
        on: transitions,
        atLeast: PlaybackGeneration(1),
        timeout: .milliseconds(50)
      )

      #expect(result == .timedOut)
    }

    /// Nothing at all still terminates.
    @Test
    func `An empty transition stream times out`() async {
      let result = await Player.awaitPlaying(
        on: Self.stateStream([]),
        atLeast: PlaybackGeneration(1),
        timeout: .milliseconds(50)
      )

      #expect(result == .timedOut)
    }

    /// Playing wins over a later error in the same stream.
    @Test
    func `Playing before an error settles`() async {
      let transitions = Self.stateStream([.playing, .error])

      let result = await Player.awaitPlaying(on: transitions, atLeast: PlaybackGeneration(1), timeout: .seconds(5))

      #expect(result == .playing)
    }

    /// #89 criterion 3. `recast(to:)` captures its stream before calling
    /// `play()`, and same-player media replacement restarts a session on a
    /// repeated `.playing`. On a stream of bare `PlayerState` the outgoing
    /// session's own `.playing` is indistinguishable from the incoming one's,
    /// so the wait would settle before the replacement had started.
    @Test
    func `A playing from the superseded generation does not settle the wait`() async {
      // Generation 1 is the session being replaced; the recast owns 2.
      let statuses = Self.statusStream([(.playing, 1), (.opening, 2), (.playing, 2)])

      let result = await Player.awaitPlaying(
        on: statuses,
        atLeast: PlaybackGeneration(2),
        timeout: .seconds(5)
      )

      #expect(result == .playing)
    }

    /// The half that makes the scoping load-bearing rather than incidental:
    /// with nothing from the new generation, the stale `.playing` must not
    /// stand in for one.
    @Test
    func `A stale playing alone times out rather than settling`() async {
      let statuses = Self.statusStream([(.playing, 1), (.paused, 1)])

      let result = await Player.awaitPlaying(
        on: statuses,
        atLeast: PlaybackGeneration(2),
        timeout: .milliseconds(50)
      )

      #expect(
        result == .timedOut,
        "a .playing from the session being replaced settled a recast that owns a later generation"
      )
    }

    /// A failure in the outgoing session is not this recast's failure.
    @Test
    func `An error from the superseded generation is ignored`() async {
      let statuses = Self.statusStream([(.error, 1), (.playing, 2)])

      let result = await Player.awaitPlaying(
        on: statuses,
        atLeast: PlaybackGeneration(2),
        timeout: .seconds(5)
      )

      #expect(result == .playing, "an error from a superseded session failed the recast that replaced it")
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

    // MARK: - Bounded waits

    /// A condition that already holds returns without suspending.
    @Test
    func `An already-true condition is ready immediately`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let result = await player.awaitCondition(timeout: .seconds(5)) { true }

      #expect(result == .ready)
    }

    /// A condition that never holds is bounded rather than hanging.
    @Test
    func `A condition that never holds reports notReady`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let result = await player.awaitCondition(timeout: .milliseconds(50)) { false }

      #expect(result == .notReady)
    }

    /// The core of the cancellation fix: the old `try? await Task.sleep` kept
    /// polling after cancellation and let the caller go on mutating. The wait
    /// must report it instead.
    @Test
    func `A cancelled wait reports cancelled rather than polling on`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let waiter = Task { @MainActor in
        await player.awaitCondition(timeout: .seconds(30)) { false }
      }
      waiter.cancel()

      #expect(await waiter.value == .cancelled)
    }

    /// An unseekable session is bounded, and the recast still settles — it
    /// just keeps its restart position.
    @Test
    func `Seekability wait reports notReady on a non-seekable session`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(isSeekable: false)

      let result = await player.awaitSeekability()

      #expect(result == .notReady)
    }

    /// A session already seekable resolves without waiting.
    @Test
    func `Seekability wait is ready when the session is seekable`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(isSeekable: true)

      let result = await player.awaitSeekability()

      #expect(result == .ready)
    }

    /// A paused recast must confirm the pause before reporting settled.
    @Test
    func `Paused wait is ready once the player reports paused`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .paused)

      let result = await player.awaitPaused()

      #expect(result == .ready)
    }

    /// A pause that is never acknowledged is bounded, which is what turns
    /// into a `timedOut` recast rather than a false `settled`.
    @Test
    func `Paused wait reports notReady when the pause is never acknowledged`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing)

      let result = await player.awaitPaused()

      #expect(result == .notReady)
    }

    /// Builds a finite status stream at a single generation, finishing after
    /// the last element.
    ///
    /// The wait is generation-scoped, so a bare `PlayerState` is no longer
    /// enough to describe an input. Cases that do not care about generation use
    /// the one the wait is scoped to, which preserves their original meaning.
    private static func stateStream(
      _ states: [PlayerState],
      generation: UInt64 = 1
    ) -> AsyncStream<PlaybackStatus> {
      AsyncStream { continuation in
        for state in states {
          continuation.yield(
            PlaybackStatus(state: state, generation: PlaybackGeneration(generation))
          )
        }
        continuation.finish()
      }
    }

    /// Builds a stream whose elements carry differing generations.
    private static func statusStream(
      _ pairs: [(PlayerState, UInt64)]
    ) -> AsyncStream<PlaybackStatus> {
      AsyncStream { continuation in
        for (state, generation) in pairs {
          continuation.yield(
            PlaybackStatus(state: state, generation: PlaybackGeneration(generation))
          )
        }
        continuation.finish()
      }
    }
  }
}
