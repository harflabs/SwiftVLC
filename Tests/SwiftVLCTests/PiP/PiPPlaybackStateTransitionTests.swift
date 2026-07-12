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
