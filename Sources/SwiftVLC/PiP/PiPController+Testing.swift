#if os(iOS) || os(macOS)
import AVKit
import CoreMedia
import Synchronization

// MARK: - Test hooks

/// In-module seams for the test suite. These forward to the internal
/// machinery without widening the public API surface.
extension PiPController {
  func _setStateForTesting(
    isPossible: Bool? = nil,
    isActive: Bool? = nil
  ) {
    if let isPossible {
      updatePiPPossible(isPossible)
    }
    if let isActive {
      updatePiPActive(isActive)
    }
  }

  nonisolated func _isPlaybackPausedForTesting(_ controller: AVPictureInPictureController) -> Bool {
    playbackDelegateProxy.pictureInPictureControllerIsPlaybackPaused(controller)
  }

  nonisolated func _timeRangeForPlaybackForTesting(_ controller: AVPictureInPictureController) -> CMTimeRange {
    playbackDelegateProxy.pictureInPictureControllerTimeRangeForPlayback(controller)
  }

  nonisolated func _didTransitionToRenderSizeForTesting(
    _ controller: AVPictureInPictureController,
    size: CMVideoDimensions
  ) {
    playbackDelegateProxy.pictureInPictureController(controller, didTransitionToRenderSize: size)
  }

  /// Hands back the internal playback-delegate proxy so tests that build
  /// an `AVPictureInPictureController.ContentSource` can pass the object
  /// that implements `AVPictureInPictureSampleBufferPlaybackDelegate`.
  nonisolated var _playbackDelegateForTesting: AVPictureInPictureSampleBufferPlaybackDelegate {
    playbackDelegateProxy
  }

  func _setPlayingForTesting(_ playing: Bool) {
    handleSetPlaying(playing)
  }

  func _pipPlaybackActiveForTesting() -> Bool {
    pipPlaybackActive
  }

  func _pendingPiPPlaybackStateForTesting() -> Bool? {
    pendingPiPPlaybackState
  }

  func _handleObservedPlaybackActivityForTesting(_ active: Bool) {
    handleObservedPlaybackActivity(active)
  }

  func _controlTimebaseRateForTesting() -> Double? {
    controlTimebase.map { CMTimebaseGetRate($0) }
  }

  func _controlTimebaseSecondsForTesting() -> Double? {
    controlTimebase.map { CMTimebaseGetTime($0).seconds }
  }

  /// Non-zero once a skip has been accepted. The controller uses it to stop
  /// the drift corrector from fighting a just-issued skip.
  func _didRecordSkipForTesting() -> Bool {
    lastSkipTimestamp != 0
  }

  func _skipByIntervalForTesting(_ skipInterval: CMTime) {
    handleSkip(by: skipInterval) {}
  }

  /// Returns how many times the completion handler ran, so "exactly once" is
  /// assertable rather than assumed.
  func _skipCompletionCountForTesting(_ skipInterval: CMTime) -> Int {
    // `handleSkip`'s completion is `@Sendable`, so the counter has to be
    // shared state rather than a captured `var`. It is called synchronously on
    // this actor today; the lock keeps the helper correct if that changes.
    let count = Mutex(0)
    handleSkip(by: skipInterval) { count.withLock { $0 += 1 } }
    return count.withLock { $0 }
  }

  func _renderSizeForTesting() -> CMVideoDimensions? {
    renderer.state.withLock { $0.renderSize }
  }
}

#endif
