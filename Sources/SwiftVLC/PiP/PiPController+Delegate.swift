#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import CLibVLC
import Dispatch
import Foundation

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
  /// Synchronizes playback state just before AVKit transitions into
  /// Picture in Picture, emits ``PiPEvent/willStart``, and clears any
  /// stale stop reason left by a previous failed or aborted attempt.
  public nonisolated func pictureInPictureControllerWillStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      pendingStopReason = nil
      // Auto-PiP starts arrive from AVKit without start() or an intent
      // transition — last chance to issue the deferred session
      // activation before the PiP window owns playback.
      activateAudioSessionIfNeeded()
      syncPlaybackStateForPictureInPicture()
      invalidatePictureInPicturePlaybackState()
      pipEventBroadcaster.broadcast(.willStart)
    }
  }

  /// Mirrors AVKit's active flag into Observation so SwiftUI can keep
  /// button labels and status UI in sync with system-driven PiP
  /// changes, and emits ``PiPEvent/didStart``.
  public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      pendingStopReason = nil
      syncPlaybackStateForPictureInPicture()
      invalidatePictureInPicturePlaybackState()
      updatePiPActive(true)
      pipEventBroadcaster.broadcast(.didStart)
    }
  }

  /// Emits ``PiPEvent/willStop(reason:)`` with the best-known reason at
  /// this instant. AVKit does not document whether the restore callback
  /// precedes this method, so the reason here may still be
  /// ``PiPStopReason/userClosed`` for a restore-driven stop; the reason
  /// on the matching `didStop` is authoritative.
  public nonisolated func pictureInPictureControllerWillStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      pipEventBroadcaster.broadcast(.willStop(reason: resolveStopReason()))
    }
  }

  /// Mirrors AVKit's active flag into Observation when PiP exits from
  /// either our own controls or the system's close affordance, and
  /// emits ``PiPEvent/didStop(reason:)`` with the resolved stop reason
  /// (see ``PiPController/pipEvents``), consuming the pending reason.
  public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      let reason = resolveStopReason()
      pendingStopReason = nil
      updatePiPActive(false)
      pipEventBroadcaster.broadcast(.didStop(reason: reason))
    }
  }

  /// Called when the user taps the PiP window's restore ("return to app")
  /// control. Forwards to ``PiPController/onRestoreUserInterface`` so the
  /// host app can bring its player UI back, then completes the AVKit
  /// transition. If no hook is set, completes immediately.
  ///
  /// The close (X) button does **not** route through here — it fires only
  /// the will-stop/did-stop callbacks (resolving to
  /// ``PiPStopReason/userClosed``) — which is how callers distinguish
  /// "restore" from "close".
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
  ) {
    pipMainActorSync {
      // Record the reason before the host app's restore hook runs, so
      // the stop delegate callbacks see it no matter how AVKit orders
      // them relative to the hook's completion.
      notePendingStopReason(.restoreRequested)
      guard let onRestoreUserInterface else {
        completionHandler(true)
        return
      }
      onRestoreUserInterface { restored in
        completionHandler(restored)
      }
    }
  }

  /// `AVPictureInPictureControllerDelegate` hook. Emits
  /// ``PiPEvent/failedToStart(_:)`` carrying the AVKit error, records
  /// ``PiPStopReason/failure`` for any stop callbacks that follow, and
  /// resyncs the observed flags so the UI doesn't stay stuck in a stale
  /// "starting" state.
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    pipMainActorSync {
      notePendingStopReason(.failure)
      updatePiPActive(false)
      pipEventBroadcaster.broadcast(.failedToStart(error))
    }
  }
}

// MARK: - Playback delegate proxy

/// A sample-buffer playback delegate that forwards to a weak
/// ``PiPController``.
///
/// `AVPictureInPictureController.ContentSource` retains its
/// `playbackDelegate` strongly at runtime (the header declares it
/// `weak`, but that only applies to the readback property — the init
/// parameter is captured strongly). Conforming ``PiPController``
/// directly would form the cycle `PiPController → pipController →
/// contentSource → playbackDelegate (self)`. This proxy breaks the
/// cycle: the controller holds the proxy strongly, the proxy holds the
/// controller weakly, and AVKit's retention of the proxy is harmless.
///
/// The forwarders run on whatever thread AVKit invokes them on. Each
/// one hops to the main actor before reading or mutating the owner.
final class PiPPlaybackDelegateProxy: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
  /// `@unchecked Sendable` is the narrow concession that lets AVKit
  /// hand the proxy between threads. The owner field is the only state,
  /// it's `weak` (ARC-atomic in Swift), and every read happens inside
  /// a `pipMainActorSync` hop to the main actor. Concurrent AVKit
  /// callbacks funnel through that bounce, so owner access is
  /// effectively serialized on the main actor even though the proxy
  /// itself is nominally nonisolated.
  weak var owner: PiPController?

  func pictureInPictureController(
    _: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    pipMainActorSync { [weak self] in
      self?.owner?.handleSetPlaying(playing)
    }
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _: AVPictureInPictureController
  ) -> CMTimeRange {
    pipMainActorSync { [weak self] in
      guard let owner = self?.owner else { return .invalid }
      let currentTime = owner.controlTimebase.map(CMTimebaseGetTime) ?? .zero
      return Self.nativePlaybackTimeRange(
        playerPointer: owner.player.pointer,
        currentTime: currentTime
      )
    }
  }

  /// Queries the native player without consulting Swift-side media mirrors.
  static func nativePlaybackTimeRange(
    playerPointer: OpaquePointer,
    currentTime: CMTime = .zero
  ) -> CMTimeRange {
    playbackTimeRange(
      playerPointer: playerPointer,
      currentTime: currentTime,
      getSnapshot: { player in
        retainedMediaLengthSnapshot(
          playerPointer: player,
          atomicSnapshotAvailable: swiftvlc_media_length_snapshot_available(),
          getAtomicSnapshot: { player in
            var native = swiftvlc_media_player_media_length_snapshot_t()
            guard
              swiftvlc_media_player_get_media_length_snapshot_if_available(
                player,
                &native
              ),
              let media = native.media
            else { return nil }
            return (media: media, length: native.length)
          },
          getRetainedMedia: { libvlc_media_player_get_media($0) },
          getMediaDuration: { libvlc_media_get_duration($0) }
        )
      },
      releaseMedia: { libvlc_media_release($0) }
    )
  }

  /// Reads one retained media identity and its matching length. New pinned
  /// binaries capture both under the player lock. Older binaries retain the
  /// media first and read duration from that exact object; they never combine
  /// `get_media` with the independently locked player-length API.
  static func retainedMediaLengthSnapshot(
    playerPointer: OpaquePointer,
    atomicSnapshotAvailable: Bool,
    getAtomicSnapshot: (OpaquePointer) -> (media: OpaquePointer, length: Int64)?,
    getRetainedMedia: (OpaquePointer) -> OpaquePointer?,
    getMediaDuration: (OpaquePointer) -> Int64
  ) -> (media: OpaquePointer, length: Int64)? {
    if atomicSnapshotAvailable {
      return getAtomicSnapshot(playerPointer)
    }

    guard let media = getRetainedMedia(playerPointer) else { return nil }
    return (media: media, length: getMediaDuration(media))
  }

  /// Maps one retained media/length pair and balances its media retain.
  static func playbackTimeRange(
    playerPointer: OpaquePointer,
    currentTime: CMTime = .zero,
    getSnapshot: (OpaquePointer) -> (media: OpaquePointer, length: Int64)?,
    releaseMedia: (OpaquePointer) -> Void
  ) -> CMTimeRange {
    guard let snapshot = getSnapshot(playerPointer) else { return .invalid }
    defer { releaseMedia(snapshot.media) }

    return playbackTimeRange(
      hasMedia: true,
      duration: snapshot.length > 0 ? .milliseconds(snapshot.length) : nil,
      currentTime: currentTime
    )
  }

  /// Maps SwiftVLC's media lifecycle onto AVKit's sample-buffer contract:
  /// invalid means there is no content, positive infinity means loaded
  /// live/indefinite content, and a positive duration means seekable VOD.
  static func playbackTimeRange(
    hasMedia: Bool,
    duration: Duration?,
    currentTime: CMTime = .zero
  ) -> CMTimeRange {
    guard hasMedia else { return .invalid }

    let durationSeconds = duration.map {
      Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    } ?? 0

    guard durationSeconds > 0 else {
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    let nominalDuration = CMTime(seconds: durationSeconds, preferredTimescale: 1000)
    let nominalRange = CMTimeRange(
      start: .zero,
      duration: nominalDuration
    )
    guard currentTime.isNumeric else { return nominalRange }
    if CMTimeRangeContainsTime(nominalRange, time: currentTime) {
      return nominalRange
    }

    // AVKit requires every finite answer to contain the display layer's
    // current control-timebase value. At an end boundary (which Core Media
    // ranges exclude) or during a small event/timebase race, extend only the
    // reported edge needed to satisfy that contract.
    let tick = CMTime(value: 1, timescale: 1000)
    let start = CMTimeCompare(currentTime, .zero) < 0 ? currentTime : .zero
    let currentEnd = CMTimeAdd(currentTime, tick)
    let end = CMTimeCompare(currentEnd, nominalDuration) > 0
      ? currentEnd
      : nominalDuration
    return CMTimeRangeFromTimeToTime(start: start, end: end)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _: AVPictureInPictureController
  ) -> Bool {
    pipMainActorSync { [weak self] in
      // Default to paused when the owner is gone so AVKit renders a
      // stable UI while teardown drains.
      !(self?.owner?.pipPlaybackActive ?? false)
    }
  }

  func pictureInPictureController(
    _: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    pipMainActorSync { [weak self] in
      guard let owner = self?.owner else {
        completionHandler()
        return
      }
      owner.handleSkip(by: skipInterval, completion: completionHandler)
    }
  }

  func pictureInPictureController(
    _: AVPictureInPictureController,
    didTransitionToRenderSize size: CMVideoDimensions
  ) {
    pipMainActorSync { [weak self] in
      self?.owner?.handleRenderSizeTransition(size)
    }
  }
}

/// AVKit may invoke the proxy's callbacks from non-main threads but
/// expects synchronous answers. Bounce onto the main actor without
/// routing through an async task so the answer is immediate.
func pipMainActorSync<T: Sendable>(
  _ body: @MainActor @Sendable () -> T
) -> T {
  if Thread.isMainThread {
    return MainActor.assumeIsolated(body)
  }
  return DispatchQueue.main.sync {
    MainActor.assumeIsolated(body)
  }
}

#endif
