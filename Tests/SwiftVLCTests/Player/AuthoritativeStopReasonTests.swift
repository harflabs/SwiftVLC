@testable import SwiftVLC
import CLibVLC
import Synchronization
import Testing

/// Issue 85 criterion 4: an unattributed stop is never reported as a confirmed
/// natural end.
///
/// Before patch 0015 reached a released engine, SwiftVLC could only *infer*
/// this: a `stopped` that no library-issued stop, error, or attached
/// `MediaListPlayer` accounted for was treated as end of media. That concludes
/// "natural end" from the absence of a known cause, so any cause it had not
/// been told about — a server closing the connection, a demuxer giving up —
/// read as a clean EOF.
///
/// The engine knows. `MediaPlayerMediaStopping` carries
/// `libvlc_stopping_reason_t`, and it precedes the `stopped` transition.
@Suite(.tags(.logic))
struct AuthoritativeStopReasonTests {
  @Test
  func `An end-of-stream reason confirms a natural end`() {
    let coordinator = PlaybackEndCoordinator()
    coordinator.noteStoppingReason(libvlc_stopping_reason_eos)

    #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
  }

  /// The case the inference got wrong. Nothing here marked a library stop or
  /// an error, so the old rule would have called this a natural end purely
  /// because it recognised no cause.
  @Test
  func `An error reason is not a natural end even with no other cause recorded`() {
    let coordinator = PlaybackEndCoordinator()
    coordinator.noteStoppingReason(libvlc_stopping_reason_error)

    #expect(
      !coordinator.consumeStoppedShouldSynthesizeEnd(),
      "a stop the engine attributed to an error was reported as a natural end"
    )
  }

  @Test
  func `A user-requested stop is not a natural end`() {
    let coordinator = PlaybackEndCoordinator()
    coordinator.noteStoppingReason(libvlc_stopping_reason_user)

    #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
  }

  /// List-player suppression still wins: advancing a playlist ends one media
  /// at eos without ending playback.
  @Test
  func `List-player suppression outranks an end-of-stream reason`() {
    let coordinator = PlaybackEndCoordinator()
    coordinator.setSuppressed(true)
    coordinator.noteStoppingReason(libvlc_stopping_reason_eos)

    #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
  }

  /// The reason describes one stop only. Leaking it into the next would let a
  /// past end of stream confirm a later, unrelated stop.
  @Test
  func `A reason does not carry into the next stop`() {
    let coordinator = PlaybackEndCoordinator()
    coordinator.noteStoppingReason(libvlc_stopping_reason_eos)
    #expect(coordinator.consumeStoppedShouldSynthesizeEnd())

    // No reason supplied for this one, and no other cause recorded.
    #expect(
      !coordinator.consumeStoppedShouldSynthesizeEnd(),
      "an unattributed successor stop was promoted to a confirmed end"
    )
  }

  /// Without a reason, a stop is not evidence of a clean end of stream.
  @Test
  func `A library-issued stop without a reason is still not a natural end`() {
    let coordinator = PlaybackEndCoordinator()

    #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
  }

  /// A reason belongs to the handle that produced it.
  ///
  /// `MediaPlayerMediaStopping` can precede a handle replacement that lands
  /// before the matching `stopped` is observed. Carrying the reason across
  /// would let the outgoing session's end of stream confirm the successor's
  /// first stop as a natural end.
  @Test
  func `A reason does not survive a handle replacement`() {
    let coordinator = PlaybackEndCoordinator()
    coordinator.noteStoppingReason(libvlc_stopping_reason_eos)

    coordinator.clearForHandleReplacement()

    #expect(
      !coordinator.consumeStoppedShouldSynthesizeEnd(),
      "an end-of-stream reason from a replaced handle confirmed the successor's stop as a natural end"
    )
  }

  /// Public filters execute inline on libVLC's callback thread. Recording the
  /// reason after fan-out lets reentrant work inspect or consume a stop before
  /// its authoritative cause exists.
  @Test
  @MainActor
  func `The stopping reason is recorded before the raw event is exposed`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let coordinator = player.endCoordinator
    let classificationObservedByFilter = Mutex<Bool?>(nil)
    let stream = player.events(policy: .unbounded) { event in
      guard case .mediaStopping = event else { return false }
      classificationObservedByFilter.withLock {
        $0 = coordinator.consumeStoppedShouldSynthesizeEnd()
      }
      return true
    }

    var event = libvlc_event_t()
    event.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
    event.u.media_player_media_stopping.reason = libvlc_stopping_reason_error
    player.eventBridge._emitNativeEventForTesting(event)

    #expect(
      classificationObservedByFilter.withLock { $0 } == false,
      "the filter classified an engine-reported error as natural end"
    )
    withExtendedLifetime(stream) {}
  }
}
