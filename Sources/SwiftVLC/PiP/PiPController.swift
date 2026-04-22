#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import CLibVLC
import Dispatch
import Observation

/// Controls Picture-in-Picture playback for a ``Player``.
///
/// `PiPController` routes video through libVLC's vmem callbacks and an
/// `AVSampleBufferDisplayLayer`, which is the only rendering path
/// AVKit's PiP can attach to. Using a `PiPController` therefore
/// replaces the default `VideoView` pipeline — do not use both on the
/// same player.
///
/// Most apps should prefer ``PiPVideoView``, which creates and owns a
/// `PiPController` behind a single SwiftUI view. Instantiate
/// `PiPController` directly only when you need fine-grained control
/// over the layer's placement or lifecycle.
///
/// ```swift
/// let controller = PiPController(player: player)
/// yourContainerView.layer.addSublayer(controller.layer)
/// controller.start()
/// ```
@Observable
@MainActor
public final class PiPController: NSObject {
  struct PlaybackDriver {
    let pause: @MainActor () -> Void
    let resume: @MainActor () -> Void
    let seek: @MainActor (Duration) -> Void

    static func live(player: Player) -> Self {
      Self(
        pause: { player.pause() },
        resume: { player.resume() },
        seek: { player.seek(to: $0) }
      )
    }
  }

  @ObservationIgnored
  private let player: Player
  @ObservationIgnored
  private let playbackDriver: PlaybackDriver
  @ObservationIgnored
  private let pauseDebounce: Duration
  @ObservationIgnored
  private let renderer: PixelBufferRenderer
  @ObservationIgnored
  private let displayLayer: AVSampleBufferDisplayLayer
  @ObservationIgnored
  private var pipController: AVPictureInPictureController?
  @ObservationIgnored
  private var rendererOpaque: Unmanaged<PixelBufferRenderer>?
  @ObservationIgnored
  private var controlTimebase: CMTimebase?
  @ObservationIgnored
  private var stateObserverTask: Task<Void, Never>?
  @ObservationIgnored
  private var possibleObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var activeObservation: NSKeyValueObservation?

  /// Tracks the playback state as PiP sees it. Updated synchronously
  /// in `setPlaying` (PiP-initiated) and by the observer (VLC-initiated,
  /// e.g. end-of-media). This ensures `isPlaybackPaused` returns a
  /// consistent value immediately, without waiting for VLC's async
  /// state transitions — which is critical because PiP queries state
  /// right after calling `setPlaying` and gets confused by stale values.
  @ObservationIgnored
  private var pipPlaybackActive: Bool = false

  /// Debounced pause task. AVKit can transiently report "paused" during
  /// skip and PiP transitions; issuing a real libVLC pause for those
  /// short-lived state flips can trip libVLC's pause/resume assertions on
  /// streaming media. We therefore wait briefly before sending the native
  /// pause command, and cancel it if AVKit settles back to playing.
  @ObservationIgnored
  private var deferredPauseTask: Task<Void, Never>?
  /// Monotonic generation used to invalidate older pause requests.
  @ObservationIgnored
  private var deferredPauseGeneration: UInt64 = 0
  /// Tracks whether PiP actually paused libVLC, so `setPlaying(true)` can
  /// avoid issuing redundant resumes for transient AVKit state changes.
  @ObservationIgnored
  private var didIssueDeferredPause: Bool = false

  /// Timestamp of the last PiP skip. The observer uses this to avoid
  /// overwriting the skip handler's timebase position with stale
  /// `currentTime` data that hasn't caught up to the seek yet.
  @ObservationIgnored
  private var lastSkipTimestamp: CFAbsoluteTime = 0

  /// Whether PiP can be started right now.
  ///
  /// Returns `false` on devices or simulators that don't support PiP,
  /// and briefly after initialization until the system has validated
  /// the layer. Observe this before enabling a "Picture-in-Picture"
  /// button in your UI.
  public private(set) var isPossible: Bool = false

  /// Whether a PiP window is currently visible.
  public private(set) var isActive: Bool = false

  /// The layer that renders video frames for both the inline and PiP
  /// presentations.
  ///
  /// Add it to your own view's layer hierarchy if you're not using
  /// ``PiPVideoView``. Size the layer to fit its container — its
  /// `videoGravity` is `.resizeAspect`.
  public var layer: AVSampleBufferDisplayLayer {
    displayLayer
  }

  /// Creates a PiP controller for the given player.
  ///
  /// Configures the audio session and hooks up vmem rendering callbacks.
  /// - Parameter player: The player to control.
  public init(player: Player) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
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

  init(
    player: Player,
    playbackDriver: PlaybackDriver,
    pauseDebounce: Duration
  ) {
    self.player = player
    self.playbackDriver = playbackDriver
    self.pauseDebounce = pauseDebounce
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
    cancelDeferredPause()
    stateObserverTask?.cancel()
    possibleObservation = nil
    activeObservation = nil
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
    updatePiPPossible(controller.isPictureInPicturePossible)
    updatePiPActive(controller.isPictureInPictureActive)
    observePiPState(of: controller)
  }

  private func observePiPState(of controller: AVPictureInPictureController) {
    possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self] controller, _
      in
      let isPossible = controller.isPictureInPicturePossible
      Task { @MainActor [weak self] in
        self?.updatePiPPossible(isPossible)
      }
    }

    activeObservation = controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) {
      [weak self] controller, _
      in
      let isActive = controller.isPictureInPictureActive
      Task { @MainActor [weak self] in
        self?.updatePiPActive(isActive)
      }
    }
  }

  private func updatePiPPossible(_ isPossible: Bool) {
    guard self.isPossible != isPossible else { return }
    self.isPossible = isPossible
  }

  private func updatePiPActive(_ isActive: Bool) {
    guard self.isActive != isActive else { return }
    self.isActive = isActive
  }

  private func cancelDeferredPause() {
    deferredPauseGeneration &+= 1
    deferredPauseTask?.cancel()
    deferredPauseTask = nil
  }

  private func scheduleDeferredPause() {
    cancelDeferredPause()

    let generation = deferredPauseGeneration
    deferredPauseTask = Task { @MainActor [weak self] in
      guard let self else { return }

      while !Task.isCancelled {
        do {
          try await Task.sleep(for: pauseDebounce)
        } catch {
          return
        }

        guard !Task.isCancelled, deferredPauseGeneration == generation, !pipPlaybackActive else { return }

        switch player.state {
        case .playing:
          didIssueDeferredPause = true
          deferredPauseTask = nil
          playbackDriver.pause()
          return
        case .opening, .buffering:
          // Avoid pausing libVLC while it is still stabilizing input state.
          // Keep waiting unless AVKit changes its mind first.
          continue
        default:
          deferredPauseTask = nil
          return
        }
      }
    }
  }

  private func resumeIfNeeded() {
    let shouldResume = didIssueDeferredPause || player.state == .paused
    didIssueDeferredPause = false
    guard shouldResume else { return }
    playbackDriver.resume()
  }

  /// AVKit can invoke PiP delegate callbacks from non-main threads.
  /// Bridge them synchronously so delegate responses stay immediate
  /// without relying on `MainActor.assumeIsolated` off the main thread.
  private nonisolated func withMainActorSync<T: Sendable>(
    _ body: @MainActor @Sendable () -> T
  ) -> T {
    if Thread.isMainThread {
      return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated(body)
    }
  }

  // MARK: - State Observation

  /// Observes player state, currentTime, duration, and rate to keep
  /// the controlTimebase and PiP UI in sync.
  private func startStateObserver() {
    stateObserverTask = Task { @MainActor [weak self] in
      var wasActive = false
      var lastDurationMs: Int64?
      var lastRate: Float = 1.0
      while !Task.isCancelled {
        guard let self else { return }

        let active = player.isActive
        let durationMs = player.duration?.milliseconds
        let rate = player.rate

        // State transition — sync timebase rate
        if active != wasActive {
          wasActive = active
          syncTimebase(playing: active)

          if active {
            didIssueDeferredPause = false
          }

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

        // Rate changed — retrack the timebase so PiP's scrubber
        // advances at the real playback speed. Without this the
        // scrubber stays at 1.0× even when the player is playing at
        // 2.0× or 0.5×, which looks like desync to the user.
        if rate != lastRate {
          lastRate = rate
          if pipPlaybackActive, let tb = controlTimebase {
            CMTimebaseSetRate(tb, rate: Float64(rate))
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
            _ = self.player.rate
          } onChange: {
            cont.resume()
          }
        }
      }
    }
  }

  private func handleSetPlaying(_ playing: Bool) {
    cancelDeferredPause()

    // Set immediately so isPlaybackPaused returns the correct value
    // when PiP queries it right after this call (before VLC catches up).
    pipPlaybackActive = playing

    if playing {
      resumeIfNeeded()
    } else {
      scheduleDeferredPause()
    }

    syncTimebase(playing: playing)
    pipController?.invalidatePlaybackState()
  }

  private func handleSkip(
    by skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    // Cancel any pending transient pause. Skip actions should not drive
    // libVLC through a pause → seek → resume cycle.
    cancelDeferredPause()

    let currentMs = player.currentTime.milliseconds
    let durationMs = player.duration?.milliseconds ?? Int64.max
    let offsetMs = Int64(skipInterval.seconds * 1000)
    let targetMs = max(0, min(currentMs + offsetMs, durationMs))

    playbackDriver.seek(.milliseconds(targetMs))

    lastSkipTimestamp = CFAbsoluteTimeGetCurrent()

    // Apple docs: "the control timebase should reflect the current
    // playback time and rate when the closure is invoked"
    if let tb = controlTimebase {
      CMTimebaseSetTime(tb, time: CMTime(
        seconds: Double(targetMs) / 1000.0,
        preferredTimescale: 1000
      ))
      CMTimebaseSetRate(tb, rate: pipPlaybackActive ? Float64(player.rate) : 0.0)
    }

    completionHandler()
  }

  /// Sets the controlTimebase time to the player's current position.
  private func syncTimebaseTime() {
    guard let tb = controlTimebase else { return }
    let t = player.currentTime
    let seconds = Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18
    CMTimebaseSetTime(tb, time: CMTime(seconds: seconds, preferredTimescale: 1000))
  }

  /// Updates the controlTimebase time and rate to match playback state.
  ///
  /// When `playing` is true the timebase tracks the player's current
  /// `rate` so PiP's scrubber animates at the real playback speed.
  private func syncTimebase(playing: Bool) {
    guard let tb = controlTimebase else { return }
    syncTimebaseTime()
    CMTimebaseSetRate(tb, rate: playing ? Float64(player.rate) : 0.0)
  }

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
    pictureInPictureControllerIsPlaybackPaused(controller)
  }

  func _setPlayingForTesting(_ playing: Bool) {
    handleSetPlaying(playing)
  }

  func _skipByIntervalForTesting(_ skipInterval: CMTime) {
    handleSkip(by: skipInterval) {}
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
  /// Mirrors AVKit's active flag into Observation so SwiftUI can keep
  /// button labels and status UI in sync with system-driven PiP changes.
  public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    withMainActorSync {
      updatePiPActive(true)
    }
  }

  /// Mirrors AVKit's active flag into Observation when PiP exits from
  /// either our own controls or the system's close affordance.
  public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    withMainActorSync {
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
    withMainActorSync {
      updatePiPActive(false)
    }
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
  // NOTE: PiP may invoke these callbacks off the main thread.
  // They still need synchronous answers, so SwiftVLC bridges them
  // onto the main actor without deferring through an async task.

  /// `AVPictureInPictureSampleBufferPlaybackDelegate` hook. Translates
  /// PiP play/pause presses into ``Player`` state changes, with the
  /// internal `pipPlaybackActive` flag kept in sync so subsequent
  /// delegate queries return the right value before libVLC's async
  /// state transition completes.
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    withMainActorSync {
      handleSetPlaying(playing)
    }
  }

  /// `AVPictureInPictureSampleBufferPlaybackDelegate` hook. Returns the
  /// media's time range so the PiP scrubber can render. When the
  /// duration isn't known yet, reports a 24-hour sentinel so the
  /// scrubber doesn't collapse to 100%; the observer invalidates the
  /// state once the real duration arrives.
  public nonisolated func pictureInPictureControllerTimeRangeForPlayback(
    _: AVPictureInPictureController
  ) -> CMTimeRange {
    let duration: Duration? = withMainActorSync { player.duration }

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

  /// `AVPictureInPictureSampleBufferPlaybackDelegate` hook. Returns the
  /// paused state as PiP sees it — backed by the internal flag so the
  /// answer is consistent right after a play/pause command, before
  /// libVLC's asynchronous state transition settles.
  public nonisolated func pictureInPictureControllerIsPlaybackPaused(
    _: AVPictureInPictureController
  ) -> Bool {
    withMainActorSync { !pipPlaybackActive }
  }

  /// `AVPictureInPictureSampleBufferPlaybackDelegate` hook. Routes PiP
  /// skip buttons into a clamped absolute seek and updates the control
  /// timebase so the PiP UI reflects the new position before libVLC's
  /// own time change arrives.
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    withMainActorSync {
      handleSkip(by: skipInterval, completion: completionHandler)
    }
  }

  /// `AVPictureInPictureSampleBufferPlaybackDelegate` hook. The PiP
  /// window resizes automatically from the sample-buffer layer; we
  /// don't need to react.
  public nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    didTransitionToRenderSize _: CMVideoDimensions
  ) {}
}

#endif
