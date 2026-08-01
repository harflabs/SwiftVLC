@testable import SwiftVLC
import Foundation
import Testing

/// A seek target, once accepted, is the authoritative timeline.
///
/// Two things used to break that. The native seek result was ignored, so a
/// refused seek still published its target and the observable timeline
/// described a position playback never reached. And the internal event stream
/// is unbounded, so time and position samples produced *before* a seek could
/// still be queued when it was accepted — applying them afterwards snapped the
/// published time back to where playback used to be. While paused there may be
/// no later native clock event to repair that, so the wrong value simply
/// stayed on screen.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekAuthorityTests {
    /// The core regression: a clock sample from before the seek must not
    /// overwrite the accepted target.
    @Test
    func `A clock sample predating an accepted seek does not snap the timeline back`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      // A sample libVLC produced before the seek, still queued.
      let stale = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .timeChanged(.seconds(3)),
        timelineRevision: player.acceptedTimelineRevision
      )

      try player.seek(to: .seconds(42))
      #expect(player.currentTime == .seconds(42))

      player.handleSourcedEvent(stale)

      #expect(
        player.currentTime == .seconds(42),
        "a pre-seek clock sample overwrote the accepted seek target"
      )
    }

    /// The same guarantee for position, which drives the scrubber.
    @Test
    func `A position sample predating an accepted seek is discarded`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      let stale = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .positionChanged(0.03),
        timelineRevision: player.acceptedTimelineRevision
      )

      try player.seek(to: .seconds(50))
      let published = player.position

      player.handleSourcedEvent(stale)

      #expect(player.position == published, "a pre-seek position sample won over the seek target")
    }

    /// A sample produced *after* the seek is the newer truth and must still be
    /// applied — the filter must not freeze the timeline.
    @Test
    func `A clock sample after an accepted seek still updates the timeline`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(42))

      let fresh = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .timeChanged(.seconds(43)),
        timelineRevision: player.acceptedTimelineRevision
      )
      player.handleSourcedEvent(fresh)

      #expect(player.currentTime == .seconds(43))
    }

    /// Rapid seeks: only the newest target survives, and a sample stamped for
    /// the earlier one cannot resurrect it.
    @Test
    func `A superseded seek's clock samples cannot resurrect its target`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      try player.seek(to: .seconds(80))

      let supersededSample = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .timeChanged(.seconds(10)),
        timelineRevision: firstRevision
      )
      player.handleSourcedEvent(supersededSample)

      #expect(player.currentTime == .seconds(80))
    }

    /// State transitions must stay lossless: only clock payloads are filtered,
    /// so a stale-stamped transition still reaches the mirror.
    @Test
    func `A stale-stamped state transition is still applied`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(42))

      let staleTransition = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .stateChanged(.playing),
        timelineRevision: 0
      )
      player.handleSourcedEvent(staleTransition)

      #expect(player.state == .playing, "a one-shot transition was dropped by the clock filter")
    }

    /// A sample carrying the seek's own revision is current, not stale, so it
    /// must be applied. After a fast (keyframe) seek this is the position
    /// playback actually landed on, which is not the requested one.
    ///
    /// This pins the boundary condition of the filter — that the comparison is
    /// `>=` and not `>`. It does **not** prove the reserve-before-native-call
    /// ordering: which revision libVLC's event thread stamps a concurrent
    /// sample with is not observable from here, and the test passes under
    /// either ordering.
    @Test
    func `A sample carrying the seek's own revision is applied`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      // Stamped with the revision the bridge hands out for this seek, which
      // is what a sample emitted during the native call would carry.
      let concurrentRevision = player.eventBridge.advanceTimelineRevision() + 1
      try player.seek(to: .seconds(42), fast: true)

      let landed = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .timeChanged(.seconds(40)),
        timelineRevision: concurrentRevision
      )
      player.handleSourcedEvent(landed)

      #expect(
        player.currentTime == .seconds(40),
        "the landed position was discarded as stale; the timeline is stuck on the requested target"
      )
    }

    /// A rejected seek must not consume the timeline: clock samples keep
    /// flowing exactly as they did before the refused request.
    @Test
    func `A rejected seek leaves the accepted timeline revision alone`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)
      let before = player.acceptedTimelineRevision

      // Out of range for the known duration, so validation refuses it.
      #expect(throws: VLCError.self) {
        try player.seek(to: .seconds(5000))
      }

      #expect(player.acceptedTimelineRevision == before)
    }

    /// Loading new media starts a new timeline, so samples from the previous
    /// one cannot update it.
    @Test
    func `A clock sample from the previous media cannot update the new timeline`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      let previousGenerationSample = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .timeChanged(.seconds(7)),
        timelineRevision: player.acceptedTimelineRevision
      )

      try player.load(Media(url: TestMedia.silenceURL))
      player.handleSourcedEvent(previousGenerationSample)

      #expect(
        player.currentTime == .zero,
        "a clock sample from the previous media updated the new one's timeline"
      )
    }

    /// `jump(by:)` is the seek entry point PiP skip controls route through, so
    /// it needs the same protection the absolute paths already have. It is
    /// also the one most exposed to it: a relative jump is issued while
    /// playback is running and clock samples are in flight, rather than from a
    /// settled scrubber drag.
    @Test
    func `A clock sample predating an accepted jump does not snap the timeline back`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      // `jump(by:)` gates on a live session; the intent flag is the
      // synchronous signal that gate reads.
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100),
        isSeekable: true
      )

      // Produced by libVLC before the jump, still queued behind it.
      let stale = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        event: .timeChanged(.seconds(10)),
        timelineRevision: player.acceptedTimelineRevision
      )

      #expect(player.jump(by: .seconds(30)))
      #expect(player.currentTime == .seconds(40))

      player.handleSourcedEvent(stale)

      #expect(
        player.currentTime == .seconds(40),
        "a pre-jump clock sample overwrote the accepted jump target"
      )
    }

    /// A refused jump must not consume the reservation, or every later clock
    /// sample would be judged stale against a revision nothing ever adopted
    /// and the published time would freeze.
    @Test
    func `A rejected jump leaves the accepted timeline revision alone`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      // No media, so there is no session to jump in and the call is refused.
      let before = player.acceptedTimelineRevision

      #expect(player.jump(by: .seconds(5)) == false)

      #expect(player.acceptedTimelineRevision == before)
    }
  }
}
