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
      observedDuration: nil,
      observedIsSeekable: false
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
      observedDuration: .seconds(120),
      observedIsSeekable: true
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
      observedDuration: nil,
      observedIsSeekable: false
    )
    #expect(becameSeekable.invalidatesPlaybackState)
    #expect(becameSeekable.requiresLinearPlayback == false)
    #expect(state.isSeekable)
    assertEffects(of: becameSeekable, expectedLinearPlayback: false)

    let becameLinear = state.consume(
      .seekableChanged(false),
      observedDuration: nil,
      observedIsSeekable: true
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
      observedDuration: nil,
      observedIsSeekable: false
    )
    #expect(payloadUpdate.invalidatesPlaybackState)
    #expect(payloadUpdate.requiresLinearPlayback == false)

    let whileStale = state.consume(
      .timeChanged(.seconds(1)),
      observedDuration: nil,
      observedIsSeekable: false
    )
    #expect(whileStale == PiPController.PlaybackStateUpdate())
    #expect(state.isSeekable)

    let mirrorCaughtUp = state.consume(
      .timeChanged(.seconds(2)),
      observedDuration: nil,
      observedIsSeekable: true
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
      observedDuration: .seconds(120),
      observedIsSeekable: true
    )
    let whileStale = state.consume(
      .timeChanged(.zero),
      observedDuration: .seconds(120),
      observedIsSeekable: true
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
      observedDuration: nil,
      observedIsSeekable: false
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

  // MARK: - Capability convergence without raw change events

  /// The regression this issue is about. libVLC does not reliably emit
  /// `MediaPlayerSeekableChanged`, so `Player` repairs seekability by polling
  /// on every state transition. Reacting only to the raw event left PiP pinned
  /// to the conservative media-changed reset — linear playback, no skip
  /// controls — for finite seekable VOD.
  @Test
  func `Finite seekable VOD converges to non-linear without a seekable event`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    _ = state.consume(.mediaChanged, observedDuration: nil, observedIsSeekable: false)

    // No `.seekableChanged` or `.lengthChanged` — only the polled values that
    // `Player` repaired, delivered alongside a state transition.
    let update = state.consume(
      .stateChanged(.playing),
      observedDuration: .seconds(600),
      observedIsSeekable: true
    )

    #expect(update.requiresLinearPlayback == false, "PiP stayed linear for seekable VOD")
    #expect(update.invalidatesPlaybackState)
    assertEffects(of: update, expectedLinearPlayback: false)
  }

  /// Unseekable live media must stay linear: convergence must not invent
  /// capability the media does not have.
  @Test
  func `Unseekable live media stays linear across state transitions`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    _ = state.consume(.mediaChanged, observedDuration: nil, observedIsSeekable: false)

    let update = state.consume(
      .stateChanged(.playing),
      observedDuration: nil,
      observedIsSeekable: false
    )

    #expect(update.requiresLinearPlayback == nil, "linear playback was re-published unnecessarily")
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  /// VOD → live: capability has to converge downwards too, not just upwards.
  @Test
  func `A transition from seekable to unseekable converges back to linear`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(600),
      isSeekable: true
    )

    let update = state.consume(
      .stateChanged(.playing),
      observedDuration: nil,
      observedIsSeekable: false
    )

    #expect(update.requiresLinearPlayback == true)
    assertEffects(of: update, expectedLinearPlayback: true)
  }

  /// A converged snapshot must not re-publish on every subsequent transition,
  /// which would churn AVKit's controls during normal playback.
  @Test
  func `An already-converged snapshot does not republish capability`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(600),
      isSeekable: true
    )

    let update = state.consume(
      .stateChanged(.playing),
      observedDuration: .seconds(600),
      observedIsSeekable: true
    )

    #expect(update.requiresLinearPlayback == nil)
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  /// Duration is adopted from polling when it was unknown, so a sliding or
  /// late-reported length still reaches PiP.
  @Test
  func `A polled duration is adopted when no length event arrived`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: true
    )

    let update = state.consume(
      .stateChanged(.playing),
      observedDuration: .seconds(300),
      observedIsSeekable: true
    )

    #expect(state.durationMilliseconds == Duration.seconds(300).milliseconds)
    #expect(update.invalidatesPlaybackState)
  }

  /// A poll that has not yet learned the length must not undo a length event
  /// that already arrived, or the two sources fight each other.
  @Test
  func `A nil polled duration does not clear a known length`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: true
    )
    _ = state.consume(
      .lengthChanged(.seconds(420)),
      observedDuration: nil,
      observedIsSeekable: true
    )

    _ = state.consume(
      .stateChanged(.playing),
      observedDuration: nil,
      observedIsSeekable: true
    )

    #expect(
      state.durationMilliseconds == Duration.seconds(420).milliseconds,
      "a polled nil duration erased a length the media had already reported"
    )
  }

  /// Media replacement resets conservatively even when the observed values
  /// still describe the previous media, so a stale capability cannot leak
  /// across the generation boundary.
  @Test
  func `Stale capability from the previous media does not survive replacement`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(600),
      isSeekable: true
    )

    let update = state.consume(
      .mediaChanged,
      observedDuration: .seconds(600),
      observedIsSeekable: true
    )

    #expect(update.requiresLinearPlayback == true)
    #expect(state.durationMilliseconds == nil)
    #expect(!state.isSeekable)
  }

  /// Known-failing: the unresolved half of #75.
  ///
  /// Convergence reads `Player`'s polled mirror, but that mirror is only
  /// reset when `Player`'s own consumer processes `.mediaChanged` — and the
  /// two consumers have deliberately unspecified relative ordering. A state
  /// transition arriving in that window resurrects the previous media's
  /// capability, which is exactly what
  /// `media reset survives following events while player mirrors are stale`
  /// guards against for `.timeChanged`.
  ///
  /// Reconciling and ignoring the mirror are both correct requirements that
  /// cannot be satisfied together from the mirror alone. Resolving it needs
  /// the media-generation-scoped snapshot the issue asks for, so that a
  /// capability value can be attributed to a generation instead of inferred
  /// from arrival order.
  @Test(.disabled("Needs generation-scoped capability; see #75"))
  func `A stale mirror must not resurrect capability on a state transition`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )
    _ = state.consume(.mediaChanged, observedDuration: .seconds(120), observedIsSeekable: true)

    let whileStale = state.consume(
      .stateChanged(.opening),
      observedDuration: .seconds(120),
      observedIsSeekable: true
    )

    #expect(whileStale.requiresLinearPlayback == nil)
    #expect(state.durationMilliseconds == nil)
    #expect(!state.isSeekable)
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
