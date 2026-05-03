#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import Dispatch
import Foundation

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
  /// Synchronizes playback state just before AVKit transitions into
  /// Picture in Picture.
  public nonisolated func pictureInPictureControllerWillStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      syncPlaybackStateForPictureInPicture()
      invalidatePictureInPicturePlaybackState()
    }
  }

  /// Mirrors AVKit's active flag into Observation so SwiftUI can keep
  /// button labels and status UI in sync with system-driven PiP changes.
  public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      syncPlaybackStateForPictureInPicture()
      invalidatePictureInPicturePlaybackState()
      updatePiPActive(true)
    }
  }

  /// Mirrors AVKit's active flag into Observation when PiP exits from
  /// either our own controls or the system's close affordance.
  public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    pipMainActorSync {
      updatePiPActive(false)
    }
  }

  /// `AVPictureInPictureControllerDelegate` hook. SwiftVLC does not
  /// propagate PiP start failures; we still resync the observed flags so
  /// the UI doesn't stay stuck in a stale "starting" state.
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    failedToStartPictureInPictureWithError _: Error
  ) {
    pipMainActorSync {
      updatePiPActive(false)
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
    let duration: Duration? = pipMainActorSync { [weak self] in
      self?.owner?.player.duration
    }

    let durationSeconds = duration.map {
      Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    } ?? 0

    let cmDuration = if durationSeconds > 0 {
      CMTime(seconds: durationSeconds, preferredTimescale: 1000)
    } else {
      // Duration unknown: PiP needs a non-zero range so the scrubber
      // renders while libVLC parses the media. Once duration arrives,
      // the state observer invalidates and AVKit re-queries.
      CMTime(seconds: 86400, preferredTimescale: 1000)
    }
    return CMTimeRange(start: .zero, duration: cmDuration)
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
