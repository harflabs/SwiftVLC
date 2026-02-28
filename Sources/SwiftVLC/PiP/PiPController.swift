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

    displayLayer.videoGravity = .resizeAspectFill
    displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    configureAudioSession()
    setupControlTimebase()
    attachCallbacks()
    setupPiPController()
    startStateObserver()
  }

  isolated deinit {
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

  /// Observes player.state via @Observable and keeps the controlTimebase
  /// rate in sync. This is critical for PiP: the system checks the timebase
  /// rate to determine if content is actively playing.
  private func startStateObserver() {
    stateObserverTask = Task { @MainActor [weak self] in
      var wasPlaying = false
      while !Task.isCancelled {
        guard let self else { return }

        let isPlaying = player.state == .playing

        if isPlaying != wasPlaying {
          wasPlaying = isPlaying
          syncTimebase(playing: isPlaying)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          withObservationTracking {
            _ = self.player.state
          } onChange: {
            cont.resume()
          }
        }
      }
    }
  }

  /// Updates the controlTimebase rate to match playback state.
  /// Rate 1.0 = playing, 0.0 = paused/stopped.
  private func syncTimebase(playing: Bool) {
    guard let tb = controlTimebase else { return }
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
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    Task { @MainActor in
      syncTimebase(playing: playing)
      if playing {
        try? player.play()
      } else {
        player.pause()
      }
    }
  }

  public nonisolated func pictureInPictureControllerTimeRangeForPlayback(
    _: AVPictureInPictureController
  ) -> CMTimeRange {
    let duration: Duration? = MainActor.assumeIsolated { player.duration }
    let currentTime: Duration = MainActor.assumeIsolated { player.currentTime }

    let durationSeconds = duration.map {
      Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    } ?? 0

    let currentSeconds = Double(currentTime.components.seconds) +
      Double(currentTime.components.attoseconds) / 1e18

    let cmDuration = CMTime(seconds: max(durationSeconds, 1), preferredTimescale: 1000)
    let cmCurrent = CMTime(seconds: currentSeconds, preferredTimescale: 1000)

    return CMTimeRange(start: cmCurrent, duration: cmDuration - cmCurrent)
  }

  public nonisolated func pictureInPictureControllerIsPlaybackPaused(
    _: AVPictureInPictureController
  ) -> Bool {
    let state: PlayerState = MainActor.assumeIsolated { player.state }
    // Only report paused for actual pause/stop states.
    // Buffering and opening are NOT paused — content is loading.
    switch state {
    case .paused, .stopped, .stopping, .error, .idle:
      return true
    case .playing, .opening, .buffering:
      return false
    }
  }

  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    Task { @MainActor in
      let ms = Int64(skipInterval.seconds * 1000)
      player.seek(by: .milliseconds(ms))
      completionHandler()
    }
  }

  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    didTransitionToRenderSize _: CMVideoDimensions
  ) {}
}

#endif
