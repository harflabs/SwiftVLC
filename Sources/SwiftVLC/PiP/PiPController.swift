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
/// AVKit's PiP can attach to. A `PiPController` replaces the default
/// `VideoView` pipeline: do not use both on the same player.
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
  fileprivate let player: Player
  @ObservationIgnored
  private let playbackDriver: PlaybackDriver
  @ObservationIgnored
  private let pauseDebounce: Duration
  @ObservationIgnored
  private let renderer: PixelBufferRenderer
  @ObservationIgnored
  private let displayLayer: AVSampleBufferDisplayLayer
  /// Holds the playback-delegate proxy for the lifetime of the
  /// controller. The `AVPictureInPictureController.ContentSource` also
  /// retains this proxy (despite the header documenting it as weak);
  /// storing it here makes ownership explicit and independent of AVKit's
  /// internal retention, which has changed across OS versions.
  ///
  /// `nonisolated` because the proxy is accessed from the
  /// AVKit-initiated delegate callbacks that may run off the main
  /// actor. Assigned once in `init`; the stored reference is
  /// effectively immutable afterwards.
  @ObservationIgnored
  private nonisolated let playbackDelegateProxy: PiPPlaybackDelegateProxy
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

  /// Playback state as PiP sees it. Updated synchronously in
  /// `setPlaying` (PiP-initiated) and by the observer (VLC-initiated,
  /// e.g. end-of-media). `isPlaybackPaused` reads this directly, so
  /// the answer is consistent without waiting for VLC's async state
  /// transitions. PiP queries state immediately after calling
  /// `setPlaying` and would otherwise see stale values.
  @ObservationIgnored
  fileprivate var pipPlaybackActive: Bool = false

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
  /// ``PiPVideoView``. Size the layer to fit its container. Its
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
    playbackDelegateProxy = PiPPlaybackDelegateProxy()

    super.init()

    playbackDelegateProxy.owner = self
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
    playbackDelegateProxy = PiPPlaybackDelegateProxy()

    super.init()

    playbackDelegateProxy.owner = self
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

    // Start paused; rate is synced with player state later.
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

    // `AVPictureInPictureController.ContentSource` declares its
    // `sampleBufferPlaybackDelegate` property as `weak` in the AVKit
    // header, but at runtime it retains the delegate strongly. Passing
    // `self` here creates an undocumented cycle:
    // `PiPController → pipController → contentSource → playbackDelegate
    // (self)`, which prevents deinit and pins the player through its
    // `let player: Player` reference. The controller also retains
    // `contentSource.sampleBufferDisplayLayer` strongly, so the
    // pixel-buffer pool and its pending `CMSampleBuffer`s stay alive
    // with the cycle. A trivial proxy with a weak back-reference breaks
    // the cycle while keeping delegate semantics identical.
    let proxy = playbackDelegateProxy
    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: proxy
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
    let debounce = pauseDebounce
    deferredPauseTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: debounce)
        } catch {
          return
        }

        // `guard let self` is placed *after* the suspension so the
        // strong binding is scoped to this iteration body only. The
        // prior shape pulled the guard above the while loop, which
        // extends the binding across every `await`, pinning `self`
        // for the full debounce window and delaying deinit.
        guard let self else { return }
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

  // MARK: - State Observation

  /// Drives the control timebase and PiP UI from player events.
  ///
  /// The previous implementation wrapped each iteration in
  /// `withCheckedContinuation { withObservationTracking { … } }`, with a
  /// `guard let self else { return }` hoisted above the `await`. Swift
  /// scopes guard-let bindings to the enclosing block, so the strong
  /// `self` binding lived across the suspension and was captured into
  /// the task's suspended frame. With external strong references gone,
  /// the suspended frame became the last holder, and nothing could wake
  /// the continuation — the observation's `onChange` was itself behind
  /// the continuation the controller was waiting on. The PiPController
  /// pinned itself until the process exited.
  ///
  /// The shape below matches `Player.startEventConsumer`: subscribe to
  /// `player.events` (the same broadcaster that drives `Player`'s own
  /// `@Observable` state), pull events via `for await`, and bind `self`
  /// strongly *inside* the loop body where the binding lifetime is a
  /// single iteration. The implicit suspension between events runs with
  /// only a weak reference in scope, so the task never prevents
  /// deinit — when the controller is dropped, the bridge finishes the
  /// stream (via `Player.deinit`) or the task sees cancellation, and
  /// the loop exits.
  private func startStateObserver() {
    let events = player.events
    stateObserverTask = Task { @MainActor [weak self] in
      var wasActive = false
      var lastDurationMs: Int64?
      var lastRate: Float = 1.0
      for await _ in events {
        guard let self else { return }

        let active = player.isActive
        let durationMs = player.duration?.milliseconds
        let rate = player.rate

        // State transition: sync the timebase rate.
        if active != wasActive {
          wasActive = active
          syncTimebase(playing: active)

          if active {
            didIssueDeferredPause = false
          }

          // Only update pipPlaybackActive and notify PiP for
          // VLC-initiated changes (end-of-media, error). For
          // PiP-initiated changes (from setPlaying), the value is
          // already correct; overriding it with VLC's delayed state
          // causes the PiP button to blink.
          if active != pipPlaybackActive {
            pipPlaybackActive = active
            pipController?.invalidatePlaybackState()
          }
        }

        // Rate changed: retrack the timebase so PiP's scrubber
        // advances at the real playback speed. Without this the
        // scrubber stays at 1.0× even when the player is running at
        // 2.0× or 0.5×, which looks like desync. `player.rate` has
        // no dedicated libVLC event, so this comparison picks the
        // change up on the next incoming event (time-changed fires
        // frequently during active playback, which is when the
        // timebase rate matters).
        if rate != lastRate {
          lastRate = rate
          if pipPlaybackActive, let tb = controlTimebase {
            CMTimebaseSetRate(tb, rate: Float64(rate))
          }
        }

        // Duration became known or changed: re-query timeRange.
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
      }
    }
  }

  fileprivate func handleSetPlaying(_ playing: Bool) {
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

  fileprivate func handleSkip(
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

  /// Hands back the internal playback-delegate proxy so tests that need
  /// to build an `AVPictureInPictureController.ContentSource` can pass
  /// the proxy directly (the public type no longer conforms to
  /// `AVPictureInPictureSampleBufferPlaybackDelegate`).
  nonisolated var _playbackDelegateForTesting: AVPictureInPictureSampleBufferPlaybackDelegate {
    playbackDelegateProxy
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
    pipMainActorSync {
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
/// one hops to the main actor before reading or mutating the owner,
/// matching the previous in-class implementation.
private final class PiPPlaybackDelegateProxy: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
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
    didTransitionToRenderSize _: CMVideoDimensions
  ) {}
}

/// AVKit may invoke the proxy's callbacks from non-main threads but
/// expects synchronous answers. Bounce onto the main actor without
/// routing through an async task so the answer is immediate.
private func pipMainActorSync<T: Sendable>(
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
