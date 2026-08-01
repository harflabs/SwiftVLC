#if os(iOS) || os(macOS)
@testable import SwiftVLC
import Testing

/// What a managed audio session does when the system takes it away.
///
/// The bug this exists for is small and total: `hasActivatedAudioSession`
/// latched on the first success and was never cleared, so after any
/// interruption `activateAudioSessionIfNeeded()` no-oped forever. Take a phone
/// call during PiP and the audio never comes back for the rest of that
/// controller's life.
///
/// Every input here arrives as an `AVAudioSession` notification, which no test
/// on this host can raise — there is no `AVAudioSession` on macOS at all. So
/// the policy is a pure function and these are its rules.
@Suite(.tags(.logic))
struct PiPAudioSessionDisruptionTests {
  private func reaction(
    _ disruption: PiPController.AudioSessionDisruption,
    playing: Bool = true,
    managed: Bool = true
  )
    -> PiPController.AudioSessionReaction {
    PiPController.reaction(
      to: disruption,
      isPlaybackIntentActive: playing,
      managesAudioSession: managed
    )
  }

  /// The regression itself. An interruption must release the latch, or nothing
  /// can ever reactivate.
  @Test
  func `An interruption releases the activation latch`() {
    let result = reaction(.interruptionBegan)
    #expect(result.clearsActivationLatch)
    // The system already deactivated us; reactivating here would fight
    // whatever took focus.
    #expect(!result.reactivates)
    #expect(!result.pausesPlayback)
  }

  @Test
  func `An interruption ending while playing reactivates`() {
    let result = reaction(.interruptionEnded(shouldResume: true))
    #expect(result.reactivates)
    #expect(!result.clearsActivationLatch, "reactivating and clearing the latch would fight each other")
  }

  /// The criterion that matters most for trust: someone who paused before the
  /// call must not find playback running after it. The system's `.shouldResume`
  /// is a hint about the interruption, not consent from the user.
  @Test
  func `An interruption ending does not resume playback the user paused`() {
    let result = reaction(.interruptionEnded(shouldResume: true), playing: false)
    #expect(!result.reactivates, "an interruption ending resumed playback the user had paused")
    #expect(result.clearsActivationLatch, "a later play must still be able to activate")
  }

  @Test
  func `An interruption ending without the resume hint does not reactivate`() {
    let result = reaction(.interruptionEnded(shouldResume: false))
    #expect(!result.reactivates)
    #expect(result.clearsActivationLatch)
  }

  /// Apple's headphone-unplug rule. Continuing would move the audio to the
  /// speaker, which is the one outcome the user certainly did not ask for.
  @Test
  func `Losing the route pauses rather than rerouting`() {
    let result = reaction(.routeLost)
    #expect(result.pausesPlayback)
    // The session is still valid, so the latch stands.
    #expect(!result.clearsActivationLatch)
    #expect(!result.reactivates)
  }

  /// A media-services reset invalidates every session object, so the category
  /// has to be set again before anything else.
  @Test
  func `A media services reset reconfigures before reactivating`() {
    let result = reaction(.mediaServicesReset)
    #expect(result.reconfiguresCategory)
    #expect(result.reactivates)
  }

  @Test
  func `A media services reset while paused reconfigures without reactivating`() {
    let result = reaction(.mediaServicesReset, playing: false)
    #expect(result.reconfiguresCategory, "the category is gone regardless of intent")
    #expect(!result.reactivates, "a reset must not take audio focus for a paused player")
    #expect(result.clearsActivationLatch)
  }

  /// A library told not to manage the session must not manage it on the way
  /// out either — including not pausing the host app's playback.
  @Test(arguments: [
    PiPController.AudioSessionDisruption.interruptionBegan,
    .interruptionEnded(shouldResume: true),
    .routeLost,
    .mediaServicesReset
  ])
  func `An unmanaged session is never touched`(disruption: PiPController.AudioSessionDisruption) {
    #expect(
      reaction(disruption, managed: false) == PiPController.AudioSessionReaction(),
      "managesAudioSession == false still produced a session mutation"
    )
  }
}

extension Integration {
  /// The effects side. The rules above decide *what* should happen; these
  /// check the controller actually does it — in particular that the latch is
  /// released, which is the whole bug.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PiPAudioSessionEffectTests {
    @MainActor
    final class PauseRecorder {
      var pauseCount = 0

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { _, _ in
            self.pauseCount += 1
            return .init(accepted: true, playbackControlRevision: nil)
          },
          resume: { true },
          cancelPendingPause: { _, _, _ in },
          shouldResume: { false },
          skip: { _ in .issued }
        )
      }
    }

    private func makeController(
      player: Player,
      recorder: PauseRecorder,
      managesAudioSession: Bool = true
    )
      -> PiPController {
      PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10),
        managesAudioSession: managesAudioSession
      )
    }

    /// The regression, end to end at the controller: before this, a latched
    /// controller stayed latched through an interruption and could never
    /// activate again.
    @Test
    func `An interruption clears the latch so a later signal can reactivate`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      controller.hasActivatedAudioSession = true

      controller.react(to: .interruptionBegan)

      #expect(
        !controller.hasActivatedAudioSession,
        "the activation latch survived an interruption; audio can never come back"
      )
      await player.shutdown()
    }

    @Test
    func `Losing the route pauses playback`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)

      controller.react(to: .routeLost)

      #expect(recorder.pauseCount == 1, "unplugging the output did not pause playback")
      await player.shutdown()
    }

    /// Criterion 4, at the effect level rather than the policy level: an
    /// unmanaged controller must not pause the host app's playback either.
    @Test
    func `An unmanaged controller neither pauses nor unlatches`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder, managesAudioSession: false)
      controller.hasActivatedAudioSession = true

      controller.react(to: .routeLost)
      controller.react(to: .interruptionBegan)

      #expect(recorder.pauseCount == 0, "an unmanaged controller paused the host app's playback")
      #expect(controller.hasActivatedAudioSession)
      await player.shutdown()
    }
  }
}
#endif
