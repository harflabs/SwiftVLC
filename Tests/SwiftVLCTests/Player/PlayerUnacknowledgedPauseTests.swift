@testable import SwiftVLC
import Testing

/// A `.pausing` transition closes on libVLC's `.paused` event, and libVLC
/// sends that event only when it actually applies the pause. These pin the
/// two ways the wrapper closes a transition that event will never answer;
/// `PauseDuringRebufferingTests` reproduces the native half against real
/// playback.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerUnacknowledgedPauseTests {
    /// A player that believes it is playing pausable media, with a pause that
    /// has already crossed into libVLC.
    private func makePlayerWithIssuedPause() throws -> Player {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPausable: true)
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      try #require(player.issuePause())
      try #require(player.pauseTransition == .pausing)
      return player
    }

    @Test
    func `An explicit resume retires the pause it cancels`() throws {
      let player = try makePlayerWithIssuedPause()
      var nativeResumes = 0
      player._nativeResumeAuthorizationOverrideForTesting = { _ in nativeResumes += 1 }

      player.resume()

      #expect(nativeResumes == 1)
      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == .resume)
      #expect(player.isPlaybackRequestedActive)
    }

    /// libVLC cancelled the deferred pause and reported nothing: the next
    /// clock update settles the recorded resume and a later pause is issued.
    @Test
    func `A later pause is issued when libVLC never acknowledged the cancelled one`() throws {
      let player = try makePlayerWithIssuedPause()
      player._nativeResumeAuthorizationOverrideForTesting = { _ in }
      player.resume()

      player._handleEventForTesting(.timeChanged(.seconds(5)))
      #expect(player.deferredPauseCommand == nil)
      #expect(player.isPlaybackRequestedActive)

      #expect(player.issuePause())
      #expect(player.pauseTransition == .pausing)
      #expect(!player.isPlaybackRequestedActive)
    }

    /// The pause did apply before the resume was processed, so libVLC still
    /// reports `.paused` then `.playing`. The intent must stay active across
    /// both, and nothing may be left open afterwards.
    @Test
    func `A pause that applied before the resume keeps the intent active`() throws {
      let player = try makePlayerWithIssuedPause()
      player._nativeResumeAuthorizationOverrideForTesting = { _ in }
      player.resume()

      player._nativePlaybackStateOverrideForTesting = .paused
      player._handleEventForTesting(.stateChanged(.paused))
      #expect(player.isPlaybackRequestedActive)
      #expect(player.pauseTransition == .resuming)

      player._nativePlaybackStateOverrideForTesting = .playing
      player._handleEventForTesting(.stateChanged(.playing))
      #expect(player.state == .playing)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `A pause still unacknowledged while playback continues is issued again`() throws {
      let player = try makePlayerWithIssuedPause()
      var nativePauses = 0
      player._pauseProbeHookForTesting = { stage in
        if stage == .nativePause { nativePauses += 1 }
      }
      let issuedAt = try #require(player.pauseTransitionBeganAt)

      player.retireUnacknowledgedPauseIfPlaybackContinues(now: issuedAt + .milliseconds(200))
      #expect(nativePauses == 0, "a pause libVLC may still acknowledge was retired early")
      #expect(player.pauseTransitionBeganAt == issuedAt)

      player.retireUnacknowledgedPauseIfPlaybackContinues(
        now: issuedAt + Player.pauseAcknowledgementTimeout
      )
      #expect(nativePauses == 1)
      #expect(player.pauseTransition == .pausing)
      #expect(player.pauseTransitionBeganAt != issuedAt)
      #expect(!player.isPlaybackRequestedActive)
    }

    /// A resume that only recorded itself behind the open transition (no
    /// native command) must not wait forever on a pause libVLC dropped.
    @Test
    func `A resume recorded behind an unacknowledged pause completes`() throws {
      let player = try makePlayerWithIssuedPause()
      #expect(player.issueResume())
      try #require(player.pauseTransition == .pausing)
      try #require(player.deferredPauseCommand == .resume)
      let issuedAt = try #require(player.pauseTransitionBeganAt)

      player.retireUnacknowledgedPauseIfPlaybackContinues(
        now: issuedAt + Player.pauseAcknowledgementTimeout
      )

      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `An unacknowledged pause is kept while the native player is not playing`() throws {
      let player = try makePlayerWithIssuedPause()
      let issuedAt = try #require(player.pauseTransitionBeganAt)
      player._nativePlaybackStateOverrideForTesting = .paused

      player.retireUnacknowledgedPauseIfPlaybackContinues(
        now: issuedAt + Player.pauseAcknowledgementTimeout
      )

      #expect(player.pauseTransition == .pausing)
      #expect(player.pauseTransitionBeganAt == issuedAt)
    }
  }
}
