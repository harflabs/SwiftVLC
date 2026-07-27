@testable import SwiftVLC
import Foundation
import Testing

/// Active media replacement must be a transaction.
///
/// `play(_:)` on a player that is already playing swaps in a fresh native
/// handle. That swap can fail synchronously — a selected renderer may be
/// rejected — and libVLC can also refuse the subsequent start. Publishing the
/// incoming media before either of those succeeded left the observable
/// surface describing media B while the outgoing handle was still playing A:
/// `currentMedia`, `duration`, `position` and the rest all belonged to
/// different generations at once.
///
/// The rule these tests pin: every public field belongs entirely to the
/// restored previous media or to a terminal outcome for the new one. There is
/// no in-between.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerReplacementTransactionTests {
    /// The native swap must not publish the incoming media itself — that is
    /// the caller's job, and only after the swap has succeeded. If this
    /// function published, a later failure could not be unwound.
    @Test
    func `Native replacement does not publish the incoming media`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = try Media(url: TestMedia.silenceURL)
      // Reference identity, captured before the `sending` transfer. Comparing
      // MRLs would pass vacuously if both happened to be nil.
      let firstIdentity = ObjectIdentifier(first)
      player.load(first)

      let incoming = try Media(url: TestMedia.twosecURL)
      try player.replaceNativePlayerForDrawablePlayback(
        target: nil,
        media: incoming
      )

      #expect(
        player.currentMedia.map(ObjectIdentifier.init) == firstIdentity,
        "the native swap published currentMedia; the caller can no longer make the commit transactional"
      )
    }

    /// The success path still commits, so the reordering did not turn a
    /// working replacement into a no-op.
    @Test
    func `A successful active replacement publishes the new media`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      // Drives `shouldReplaceNativePlayerBeforePlaybackLoad` true so
      // `play(_:)` takes the handle-replacement branch rather than `load`.
      player._setStateForTesting(state: .playing)

      let replacement = try Media(url: TestMedia.twosecURL)
      let replacementIdentity = ObjectIdentifier(replacement)
      try? player.play(replacement)

      #expect(player.currentMedia.map(ObjectIdentifier.init) == replacementIdentity)
      #expect(player.duration == nil, "media-derived state was not reset for the new generation")
      #expect(player.position == 0)
      #expect(player.currentTime == .zero)
    }

    /// A rejected start leaves no session for the current media, so an active
    /// state can only have been inherited from the previous one and must not
    /// survive — that is exactly the mixed identity this issue is about.
    ///
    /// Driven through the pure rule rather than a real rejection:
    /// `libvlc_media_player_play` returning `-1` is not forceable from a
    /// test, and notably does *not* happen on a player with no media.
    @Test
    func `A rejected start replaces an inherited active state`() {
      for active in [PlayerState.playing, .opening, .buffering] {
        #expect(
          Player.stateAfterRejectedStart(previous: active) == .error,
          "a start rejection kept the previous session's \(active) state"
        )
      }
    }

    /// A rejected start from a non-active state must not invent a failure the
    /// caller never had. Only an inherited *active* state is the problem.
    @Test
    func `A rejected start from a settled player does not fabricate a session`() {
      for settled in [PlayerState.idle, .stopped, .paused, .stopping, .error] {
        #expect(
          Player.stateAfterRejectedStart(previous: settled) == settled,
          "a start rejection rewrote the settled \(settled) state"
        )
      }
    }

    /// Whatever the outcome, the media identity and the timeline fields must
    /// agree with each other — never one from each generation.
    @Test
    func `Public fields never mix generations across a replacement`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = try Media(url: TestMedia.silenceURL)
      let firstIdentity = ObjectIdentifier(first)
      player.load(first)
      player._setStateForTesting(
        state: .playing,
        currentTime: .seconds(5),
        duration: .seconds(30),
        position: 0.5
      )

      let replacement = try Media(url: TestMedia.twosecURL)
      let replacementIdentity = ObjectIdentifier(replacement)
      try? player.play(replacement)

      if player.currentMedia.map(ObjectIdentifier.init) == replacementIdentity {
        // Committed to the new generation: the old timeline must be gone.
        #expect(player.duration == nil)
        #expect(player.currentTime == .zero)
        #expect(player.position == 0)
      } else {
        // Restored: the previous media and its timeline stay intact together.
        #expect(player.currentMedia.map(ObjectIdentifier.init) == firstIdentity)
        #expect(player.duration == .seconds(30))
      }
    }
  }
}
