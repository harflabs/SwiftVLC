#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import CLibVLC
import Observation

/// Controls Picture-in-Picture playback for a ``Player``.
///
/// When PiP is used, all rendering goes through vmem callbacks →
/// `AVSampleBufferDisplayLayer` (both inline and PiP windows).
/// This is mutually exclusive with `libvlc_media_player_set_nsobject()`.
///
/// ```swift
/// let controller = PiPController(player: player)
/// controller.start()
/// ```
@MainActor
public final class PiPController: NSObject {
  private let player: Player
  private let renderer: PixelBufferRenderer
  private let displayLayer: AVSampleBufferDisplayLayer
  private var pipController: AVPictureInPictureController?
  private var rendererOpaque: Unmanaged<PixelBufferRenderer>?
  private var controlTimebase: CMTimebase?
  private var stateObserverTask: Task<Void, Never>?

  /// Tracks the playback state as PiP sees it. Updated synchronously
  /// in `setPlaying` (PiP-initiated) and by the observer (VLC-initiated,
  /// e.g. end-of-media). This ensures `isPlaybackPaused` returns a
  /// consistent value immediately, without waiting for VLC's async
  /// state transitions — which is critical because PiP queries state
  /// right after calling `setPlaying` and gets confused by stale values.
  private var pipPlaybackActive: Bool = false

  /// Deferred pause task. PiP calls `setPlaying(false)` before every skip,
  /// then `setPlaying(true)` after. Pausing VLC synchronously causes a
  /// visible blink. By deferring the actual `player.pause()` to the next
  /// run-loop iteration, `skipByInterval` can cancel it — avoiding a
  /// pointless pause→seek→resume cycle.
  private var deferredPauseTask: Task<Void, Never>?

  /// Timestamp of the last PiP skip. The observer uses this to avoid
  /// overwriting the skip handler's timebase position with stale
  /// `currentTime` data that hasn't caught up to the seek yet.
  private var lastSkipTimestamp: CFAbsoluteTime = 0

  /// Whether PiP can be activated.
  public var isPossible: Bool {
    pipController?.isPictureInPicturePossible ?? false
  }

  /// Whether PiP is currently active.
  public var isActive: Bool {
    pipController?.isPictureInPictureActive ?? false
  }

  /// The display layer used for rendering. Add this to your view hierarchy.
  public var layer: AVSampleBufferDisplayLayer {
    displayLayer
  }

  /// Creates a PiP controller for the given player.
  ///
  /// Configures the audio session and hooks up vmem rendering callbacks.
  /// - Parameter player: The player to control.
  public init(player: Player) {
    self.player = player
    displayLayer = AVSampleBufferDisplayLayer()
    renderer = PixelBufferRenderer(displayLayer: displayLayer)

    super.init()

    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    configureAudioSession()
    setupControlTimebase()
    attachCallbacks()
    setupPiPController()
    startStateObserver()
  }

  isolated deinit {
    deferredPauseTask?.cancel()
    stateObserverTask?.cancel()
    libvlc_video_set_callbacks(player.pointer, nil, nil, nil, nil)
    libvlc_video_set_format_callbacks(player.pointer, nil, nil)
    rendererOpaque?.release()
    renderer.setDisplayLayer(nil)
    renderer.setTimebase(nil)
  }

  // MARK: - Public API

  /// Starts Picture-in-Picture if possible.
  public func start() {
    pipController?.startPictureInPicture()
  }

  /// Stops Picture-in-Picture.
  public func stop() {
    pipController?.stopPictureInPicture()
  }

  /// Toggles Picture-in-Picture on/off.
  public func toggle() {
    if isActive {
      stop()
    } else {
      start()
    }
  }

  // MARK: - Setup

  private func configureAudioSession() {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
    #endif
  }

  private func setupControlTimebase() {
    var tb: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &tb
    )
    guard let tb else { return }

    // Start paused — rate will be synced with player state
    CMTimebaseSetTime(tb, time: .zero)
    CMTimebaseSetRate(tb, rate: 0.0)
    displayLayer.controlTimebase = tb
    controlTimebase = tb

    // Give the renderer access to the timebase for frame PTS
    renderer.setTimebase(tb)
  }

  private func attachCallbacks() {
    let opaque = Unmanaged.passRetained(renderer)
    rendererOpaque = opaque
    let ptr = opaque.toOpaque()

    // Set the opaque pointer for vmem callbacks
    libvlc_video_set_callbacks(
      player.pointer,
      pixelBufferLockCallback,
      pixelBufferUnlockCallback,
      pixelBufferDisplayCallback,
      ptr
    )

    libvlc_video_set_format_callbacks(
      player.pointer,
      pixelBufferFormatCallback,
      pixelBufferCleanupCallback
    )
  }

  private func setupPiPController() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    #if os(iOS)
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    #endif
    pipController = controller
  }

  // MARK: - State Observation

  /// Observes player state, currentTime, and duration to keep the
  /// controlTimebase and PiP UI in sync.
  private func startStateObserver() {
    stateObserverTask = Task { @MainActor [weak self] in
      var wasActive = false
      var lastDurationMs: Int64?
      while !Task.isCancelled {
        guard let self else { return }

        let active = player.isActive
        let durationMs = player.duration?.milliseconds

        // State transition — sync timebase rate
        if active != wasActive {
          wasActive = active
          syncTimebase(playing: active)

          // Only update pipPlaybackActive and notify PiP for
          // VLC-initiated changes (end-of-media, error). For
          // PiP-initiated changes (from setPlaying), the value
          // is already correct — don't override it with VLC's
          // delayed state which causes blinking.
          if active != pipPlaybackActive {
            pipPlaybackActive = active
            pipController?.invalidatePlaybackState()
          }
        }

        // Duration became known or changed — re-query timeRange
        if durationMs != lastDurationMs {
          lastDurationMs = durationMs
          pipController?.invalidatePlaybackState()
        }

        // Sync timebase when player position diverges significantly
        // (e.g., seek from the app's own controls outside PiP).
        // Guard against overwriting the skip handler's timebase.
        if active, let tb = controlTimebase {
          let timeSinceSkip = CFAbsoluteTimeGetCurrent() - lastSkipTimestamp
          if timeSinceSkip > 1.0 {
            let t = player.currentTime
            let playerSec = Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18
            let tbSec = CMTimebaseGetTime(tb).seconds
            if abs(playerSec - tbSec) > 2.0 {
              CMTimebaseSetTime(tb, time: CMTime(seconds: playerSec, preferredTimescale: 1000))
            }
          }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          withObservationTracking {
            _ = self.player.state
            _ = self.player.currentTime
            _ = self.player.duration
          } onChange: {
            cont.resume()
          }
        }
      }
    }
  }

  /// Sets the controlTimebase time to the player's current position.
  private func syncTimebaseTime() {
    guard let tb = controlTimebase else { return }
    let t = player.currentTime
    let seconds = Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18
    CMTimebaseSetTime(tb, time: CMTime(seconds: seconds, preferredTimescale: 1000))
  }

  /// Updates the controlTimebase time and rate to match playback state.
  private func syncTimebase(playing: Bool) {
    guard let tb = controlTimebase else { return }
    syncTimebaseTime()
    CMTimebaseSetRate(tb, rate: playing ? 1.0 : 0.0)
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
  public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _: AVPictureInPictureController
  ) {}

  public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {}

  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    failedToStartPictureInPictureWithError _: Error
  ) {}
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
  // NOTE: All delegate methods are called by the PiP system on the main thread.
  // They MUST execute synchronously (MainActor.assumeIsolated) — not via
  // Task { @MainActor in }, which defers to the next run-loop iteration.
  // The PiP system queries state immediately after calling these; if the
  // action hasn't executed yet the UI reverts to stale state.

  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    MainActor.assumeIsolated {
      deferredPauseTask?.cancel()
      deferredPauseTask = nil

      // Set immediately so isPlaybackPaused returns the correct value
      // when PiP queries it right after this call (before VLC catches up).
      pipPlaybackActive = playing

      if playing {
        // Use resume (unpause) rather than play (restart) — the player
        // was paused, not stopped, so unpause is the correct operation.
        player.resume()
      } else {
        // Defer the actual VLC pause to the next run-loop iteration.
        // PiP calls setPlaying(false) before every skip, then
        // setPlaying(true) after. If skipByInterval arrives before
        // this executes, it cancels the task — so VLC never pauses
        // and there's no visible blink.
        deferredPauseTask = Task { @MainActor [weak self] in
          guard let self, !Task.isCancelled else { return }
          player.pause()
        }
      }
      syncTimebase(playing: playing)
      pipController?.invalidatePlaybackState()
    }
  }

  public nonisolated func pictureInPictureControllerTimeRangeForPlayback(
    _: AVPictureInPictureController
  ) -> CMTimeRange {
    let duration: Duration? = MainActor.assumeIsolated { player.duration }

    let durationSeconds = duration.map {
      Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    } ?? 0

    // When duration is unknown (nil → 0), use a large sentinel so the
    // scrubber doesn't show 100% before the real duration is known.
    // Once known, the observer invalidates and PiP re-queries.
    let cmDuration = if durationSeconds > 0 {
      CMTime(seconds: durationSeconds, preferredTimescale: 1000)
    } else {
      CMTime(seconds: 86400, preferredTimescale: 1000)
    }

    return CMTimeRange(start: .zero, duration: cmDuration)
  }

  public nonisolated func pictureInPictureControllerIsPlaybackPaused(
    _: AVPictureInPictureController
  ) -> Bool {
    MainActor.assumeIsolated { !pipPlaybackActive }
  }

  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    MainActor.assumeIsolated {
      // Cancel the deferred pause — VLC should keep playing through the skip
      deferredPauseTask?.cancel()
      deferredPauseTask = nil

      let currentMs = player.currentTime.milliseconds
      let durationMs = player.duration?.milliseconds ?? Int64.max
      let offsetMs = Int64(skipInterval.seconds * 1000)
      let targetMs = max(0, min(currentMs + offsetMs, durationMs))

      // Relative seek — same API the demo app skip buttons use
      player.seek(by: .milliseconds(offsetMs))

      lastSkipTimestamp = CFAbsoluteTimeGetCurrent()

      // Apple docs: "the control timebase should reflect the current
      // playback time and rate when the closure is invoked"
      if let tb = controlTimebase {
        CMTimebaseSetTime(tb, time: CMTime(
          seconds: Double(targetMs) / 1000.0,
          preferredTimescale: 1000
        ))
        CMTimebaseSetRate(tb, rate: 1.0)
      }

      completionHandler()
    }
  }

  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    didTransitionToRenderSize _: CMVideoDimensions
  ) {}
}

#endif
