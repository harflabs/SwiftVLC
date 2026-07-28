#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Testing

@Suite(.tags(.logic, .mainActor))
@MainActor struct PiPPlaybackStateTransitionTests {
  @Test
  func `loading live media invalidates even when duration remains unknown`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let update = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )

    #expect(update.invalidatesPlaybackState)
    #expect(update.requiresLinearPlayback == true)
    assertEffects(of: update, expectedLinearPlayback: true)
  }

  @Test
  func `media replacement ignores stale pre-event player state`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )

    let update = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: Duration.seconds(120).milliseconds,
        isSeekable: true
      )
    )

    #expect(update.invalidatesPlaybackState)
    #expect(update.requiresLinearPlayback == true)
    #expect(state.durationMilliseconds == nil)
    #expect(state.isSeekable == false)
  }

  @Test
  func `seekability payload wins subscriber race and updates linear playback`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let becameSeekable = state.consume(
      .seekableChanged(true),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )
    #expect(becameSeekable.invalidatesPlaybackState)
    #expect(becameSeekable.requiresLinearPlayback == false)
    #expect(state.isSeekable)
    assertEffects(of: becameSeekable, expectedLinearPlayback: false)

    let becameLinear = state.consume(
      .seekableChanged(false),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: true
      )
    )
    #expect(becameLinear.invalidatesPlaybackState)
    #expect(becameLinear.requiresLinearPlayback == true)
    #expect(state.isSeekable == false)
    assertEffects(of: becameLinear, expectedLinearPlayback: true)
  }

  @Test
  func `seekability payload survives following events while player mirror is stale`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let payloadUpdate = state.consume(
      .seekableChanged(true),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )
    #expect(payloadUpdate.invalidatesPlaybackState)
    #expect(payloadUpdate.requiresLinearPlayback == false)

    let whileStale = state.consume(
      .timeChanged(.seconds(1)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )
    #expect(whileStale == PiPController.PlaybackStateUpdate())
    #expect(state.isSeekable)

    let mirrorCaughtUp = state.consume(
      .timeChanged(.seconds(2)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: true
      )
    )
    #expect(mirrorCaughtUp == PiPController.PlaybackStateUpdate())
    #expect(state.isSeekable)
  }

  @Test
  func `media reset survives following events while player mirrors are stale`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )

    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: Duration.seconds(120).milliseconds,
        isSeekable: true
      )
    )
    let whileStale = state.consume(
      .timeChanged(.zero),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: Duration.seconds(120).milliseconds,
        isSeekable: true
      )
    )

    #expect(whileStale == PiPController.PlaybackStateUpdate())
    #expect(state.durationMilliseconds == nil)
    #expect(state.isSeekable == false)
  }

  @Test
  func `duration payload wins subscriber race and invalidates`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let update = state.consume(
      .lengthChanged(.seconds(90)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )

    #expect(update.invalidatesPlaybackState)
    #expect(state.durationMilliseconds == 90000)
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  @Test
  func `native range query ignores a stale finite Player mirror after live media change`() throws {
    let staleMirrorRange = PiPPlaybackDelegateProxy.playbackTimeRange(
      hasMedia: true,
      duration: .seconds(120)
    )
    #expect(staleMirrorRange.duration.seconds == 120)

    let retainedMedia = try #require(OpaquePointer(bitPattern: 0x1))
    var releaseCount = 0
    let nativeRange = try PiPPlaybackDelegateProxy.playbackTimeRange(
      playerPointer: #require(OpaquePointer(bitPattern: 0x2)),
      getSnapshot: { _ in (retainedMedia, 0) },
      releaseMedia: { media in
        #expect(media == retainedMedia)
        releaseCount += 1
      }
    )

    #expect(nativeRange.isValid)
    #expect(nativeRange.duration.isPositiveInfinity)
    #expect(releaseCount == 1)
  }

  // MARK: - Capability convergence

  /// The regression this issue is about. libVLC does not reliably emit
  /// `MediaPlayerSeekableChanged`, so `Player` repairs seekability by polling.
  /// Reacting only to the raw event left finite seekable VOD pinned to the
  /// conservative media-changed reset: linear playback, no skip controls.
  @Test
  func `Finite seekable VOD converges without a seekable event`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    // `Player` has already processed the media change, so the snapshot holds
    // the reset values under the new generation.
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    let update = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 600_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == false, "PiP stayed linear for seekable VOD")
    assertEffects(of: update, expectedLinearPlayback: false)
  }

  /// Steady playback can run without another state transition, so convergence
  /// has to be reachable from a clock tick too.
  @Test
  func `Capability converges on a clock tick`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    let update = state.consume(
      .timeChanged(.seconds(5)),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 600_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == false)
    assertEffects(of: update, expectedLinearPlayback: false)
  }

  /// **The case that broke my first attempt.** A state transition arriving
  /// before `Player` has processed the media change must not resurrect the
  /// previous media's capability — the generation is what proves the snapshot
  /// is still describing the outgoing media.
  @Test
  func `A stale mirror does not resurrect capability on a state transition`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )
    let stale = PlayerCapabilitySnapshot(
      generation: 1,
      durationMilliseconds: 120_000,
      isSeekable: true
    )
    _ = state.consume(.mediaChanged, capability: stale)

    let update = state.consume(.stateChanged(.opening), capability: stale)

    #expect(update.requiresLinearPlayback == nil, "stale capability was adopted")
    #expect(state.durationMilliseconds == nil)
    #expect(!state.isSeekable)
  }

  /// Once the generation moves past the reset, the same values are the *new*
  /// media's and must be adopted.
  @Test
  func `Capability is adopted once the generation moves on`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: 120_000,
        isSeekable: true
      )
    )

    let update = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 300_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == false)
    #expect(state.durationMilliseconds == 300_000)
  }

  /// Unseekable live media must stay linear: convergence must not invent
  /// capability the media does not have.
  @Test
  func `Unseekable live media stays linear`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    let update = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    #expect(update.requiresLinearPlayback == nil, "linear playback was republished")
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  /// A clock tick on a converged snapshot must produce nothing — invalidating
  /// AVKit at the clock rate would be worse than the bug being fixed.
  @Test
  func `A clock tick on a converged snapshot produces no update`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(600),
      isSeekable: true
    )

    let update = state.consume(
      .timeChanged(.seconds(5)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: 600_000,
        isSeekable: true
      )
    )

    #expect(update == PiPController.PlaybackStateUpdate())
  }

  /// A poll that has not learned the length must not undo a length event that
  /// already arrived, or the two sources fight each other.
  @Test
  func `A polled nil duration does not clear a length payload`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: true
    )
    _ = state.consume(
      .lengthChanged(.seconds(420)),
      capability: PlayerCapabilitySnapshot(generation: 1, isSeekable: true)
    )

    _ = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(generation: 1, isSeekable: true)
    )

    #expect(
      state.durationMilliseconds == 420_000,
      "a polled nil duration erased a length the media had already reported"
    )
  }

  private func assertEffects(
    of update: PiPController.PlaybackStateUpdate,
    expectedLinearPlayback: Bool?
  ) {
    var invalidationCount = 0
    var linearPlaybackValues: [Bool] = []

    PiPController.applyPlaybackStateUpdate(
      update,
      setRequiresLinearPlayback: { linearPlaybackValues.append($0) },
      invalidatePlaybackState: { invalidationCount += 1 }
    )

    #expect(invalidationCount == 1)
    #expect(linearPlaybackValues == expectedLinearPlayback.map { [$0] } ?? [])
  }
}
#endif
