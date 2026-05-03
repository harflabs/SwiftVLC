#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import CLibVLC
import Dispatch
import Observation
import Synchronization

/// Controls Picture-in-Picture playback for a ``Player``.
///
/// When instantiated directly, `PiPController` routes video through
/// libVLC's vmem callbacks and an `AVSampleBufferDisplayLayer`. That
/// sample-buffer path replaces the default `VideoView` pipeline: do
/// not use both on the same player.
///
/// Most apps should prefer ``PiPVideoView``, which creates and owns a
/// `PiPController` behind a single SwiftUI view. On macOS that view owns
/// VLC's native drawable container and moves the whole container into the
/// system PiP presenter, avoiding AVKit's sample-buffer mirror path.
///
/// ```swift
/// let controller = PiPController(player: player)
/// yourContainerView.layer.addSublayer(controller.layer)
/// controller.start()
/// ```
@Observable
@MainActor
public final class PiPController: NSObject {
  /// Whether the macOS PiP backend may use Apple's private
  /// `PIPViewController` (loaded from `PIP.framework`) to host the
  /// floating PiP window.
  ///
  /// **Default: `false`.** The public AVKit sample-buffer PiP path on
  /// macOS mirrors video through a `CALayerHost` that, on the macOS
  /// releases SwiftVLC supports, crops to 1:1 instead of scaling into
  /// the PiP panel. SwiftVLC therefore disables macOS PiP by default
  /// instead of loading a private framework implicitly.
  ///
  /// Set this to `true` only when your distribution channel accepts
  /// private API use. With the flag `false`, `PiPController.isPossible`
  /// returns `false` on macOS and `start()` is a no-op. iOS PiP is
  /// unaffected (it uses only public AVKit).
  ///
  /// Read-write at any time; takes effect on the next backend
  /// `refreshPossible()` (each `attach`/`start` call). For most apps,
  /// set this once at app launch and leave it.
  public nonisolated static var allowsPrivateMacOSAPI: Bool {
    get { allowsPrivateMacOSAPIStorage.load(ordering: .acquiring) }
    set { allowsPrivateMacOSAPIStorage.store(newValue, ordering: .releasing) }
  }

  /// Backing storage for ``allowsPrivateMacOSAPI``. `Atomic<Bool>` from
  /// `Synchronization` so reads/writes are well-defined under strict
  /// concurrency without taking a Mutex on every check.
  private nonisolated static let allowsPrivateMacOSAPIStorage = Atomic<Bool>(false)

  struct PlaybackDriver {
    let pause: @MainActor () -> Bool
    let resume: @MainActor () -> Bool
    let cancelPendingPause: @MainActor () -> Void
    let shouldResume: @MainActor () -> Bool
    let seek: @MainActor (Duration) -> Void

    static func live(player: Player) -> Self {
      Self(
        pause: { player.issuePause() },
        resume: { player.issueResume() },
        cancelPendingPause: { player.cancelPendingPause() },
        shouldResume: { player.shouldResumeForExternalPlayRequest },
        seek: { player.seek(to: $0) }
      )
    }
  }

  @ObservationIgnored
  let player: Player
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
  private var rendererContext: PixelBufferRendererCallbackContext?
  @ObservationIgnored
  private var rendererOpaque: UnsafeMutableRawPointer?
  @ObservationIgnored
  private var controlTimebase: CMTimebase?
  @ObservationIgnored
  private var stateObserverTask: Task<Void, Never>?
  @ObservationIgnored
  private var playbackIntentObserverTask: Task<Void, Never>?
  @ObservationIgnored
  private var possibleObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var activeObservation: NSKeyValueObservation?
  #if os(macOS)
  @ObservationIgnored
  private var nativeBackend: MacNativePiPBackend?
  #endif

  /// Playback state as PiP sees it. Updated synchronously in
  /// `setPlaying` (PiP-initiated) and by the observer (VLC-initiated,
  /// e.g. end-of-media). `isPlaybackPaused` reads this directly, so
  /// the answer is consistent without waiting for VLC's async state
  /// transitions. PiP queries state immediately after calling
  /// `setPlaying` and would otherwise see stale values.
  @ObservationIgnored
  var pipPlaybackActive: Bool = false
  /// Desired playback state from the PiP controls while libVLC is still
  /// catching up. During this window player events can still report the
  /// old state, so the event observer must not overwrite
  /// `pipPlaybackActive` until native playback reaches the requested
  /// state or exits playback entirely.
  @ObservationIgnored
  private var pendingPiPPlaybackState: Bool?

  /// State of the deferred-pause debouncer.
  ///
  /// AVKit can transiently report "paused" during skip and PiP
  /// transitions; issuing a real libVLC pause for those short-lived
  /// state flips can trip libVLC's pause/resume assertions on streaming
  /// media. We wait briefly before sending the native pause command,
  /// and cancel it if AVKit settles back to playing. The generation
  /// counter rides inside `.scheduled` so a late-firing wake-up from
  /// a cancelled task can detect that it is stale and exit cleanly.
  @ObservationIgnored
  private var deferredPause: DeferredPauseState = .idle

  /// State of PiP's pause-debouncing state machine. See ``deferredPause``.
  fileprivate enum DeferredPauseState {
    /// No deferred pause in flight; libVLC matches PiP intent.
    case idle
    /// A deferred-pause task is sleeping. `task` is the in-flight task,
    /// and `generation` is its monotonic id — the task checks the
    /// current `generation` on wake-up and exits if it has been bumped
    /// (meaning a newer task replaced it).
    case scheduled(task: Task<Void, Never>, generation: UInt64)
    /// PiP actually paused libVLC. The next `setPlaying(true)` should
    /// issue a resume to undo this pause, even if libVLC is currently
    /// inactive (so we don't strand the player in a paused state).
    case issued

    /// Generation id for the next `.scheduled` case. Reads the highest
    /// observed generation and increments it. Always > 0; 0 is unused.
    static func nextGeneration(after current: DeferredPauseState) -> UInt64 {
      switch current {
      case .idle, .issued: 1
      case .scheduled(_, let g): g &+ 1
      }
    }
  }

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
    startPlaybackIntentObserver()
  }

  #if os(macOS)
  init(
    player: Player,
    nativeBackend: MacNativePiPBackend
  ) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
    displayLayer = AVSampleBufferDisplayLayer()
    renderer = PixelBufferRenderer(displayLayer: displayLayer)
    playbackDelegateProxy = PiPPlaybackDelegateProxy()
    self.nativeBackend = nativeBackend

    super.init()

    playbackDelegateProxy.owner = self
    nativeBackend.owner = self
    updatePiPPossible(nativeBackend.isPossible)
    updatePiPActive(nativeBackend.isActive)
    startStateObserver()
    startPlaybackIntentObserver()
  }
  #endif

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
    startPlaybackIntentObserver()
  }

  isolated deinit {
    cancelDeferredPause()
    stateObserverTask?.cancel()
    playbackIntentObserverTask?.cancel()
    possibleObservation = nil
    activeObservation = nil
    #if os(macOS)
    nativeBackend?.owner = nil
    #endif
    renderer.setDisplayLayer(nil)
    renderer.setTimebase(nil)
    if let rendererContext, let rendererOpaque {
      let nativeState = PlayerState(from: libvlc_media_player_get_state(player.pointer))
      let mayHaveInheritedCallbacks = switch nativeState {
      case .idle, .stopped, .error:
        player.isPlaybackRequestedActive
      case .opening, .buffering, .playing, .paused, .stopping:
        true
      }
      libvlc_video_set_callbacks(player.pointer, nil, nil, nil, nil)
      libvlc_video_set_format_callbacks(player.pointer, nil, nil)
      rendererContext.requestRetirement(
        opaque: rendererOpaque,
        deferIfVoutMayBeOpening: mayHaveInheritedCallbacks
      )
      if mayHaveInheritedCallbacks {
        scheduleRetiredRendererContextRelease(rendererContext, opaque: rendererOpaque)
      }
    }
  }

  // MARK: - Public API

  /// Starts Picture-in-Picture if possible and media is loaded.
  public func start() {
    #if os(macOS)
    if let nativeBackend {
      nativeBackend.start()
      return
    }
    #endif
    guard let pipController else { return }
    guard player.currentMedia != nil else { return }
    pipController.startPictureInPicture()
  }

  /// Stops Picture-in-Picture.
  public func stop() {
    #if os(macOS)
    if let nativeBackend {
      nativeBackend.stop()
      return
    }
    #endif
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
    let context = PixelBufferRendererCallbackContext(renderer: renderer)
    let retained = Unmanaged.passRetained(context)
    rendererContext = context
    let ptr = retained.toOpaque()
    rendererOpaque = ptr

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

  private func scheduleRetiredRendererContextRelease(
    _ context: PixelBufferRendererCallbackContext,
    opaque: UnsafeMutableRawPointer
  ) {
    guard let retainedPlayer = libvlc_media_player_retain(player.pointer) else {
      context.releaseRetiredOpaqueRetainIfNoOpenVout(opaque: opaque)
      return
    }
    nonisolated(unsafe) let playerPointer = retainedPlayer
    nonisolated(unsafe) let contextOpaque = opaque

    DispatchQueue.global(qos: .utility).async {
      context.releaseRetiredOpaqueRetainWhenPlayerIsQuiescent(
        opaque: contextOpaque,
        player: playerPointer
      )
      libvlc_media_player_release(playerPointer)
    }
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
    possibleObservation = controller.observe(
      \.isPictureInPicturePossible,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isPossible = controller.isPictureInPicturePossible
      Task { @MainActor [weak self] in
        self?.updatePiPPossible(isPossible)
      }
    }

    activeObservation = controller.observe(
      \.isPictureInPictureActive,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
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

  func updatePiPActive(_ isActive: Bool) {
    guard self.isActive != isActive else { return }
    self.isActive = isActive
  }

  func invalidatePictureInPicturePlaybackState() {
    #if os(macOS)
    if let nativeBackend {
      nativeBackend.invalidatePlaybackState()
      return
    }
    #endif
    pipController?.invalidatePlaybackState()
  }

  /// Cancels any in-flight scheduled pause. Mirrors the pre-refactor
  /// semantics: this **only** cancels the `.scheduled` task. An already-
  /// `.issued` pause is preserved — `requestResumeIfNeeded` reads it to
  /// decide whether to issue a libVLC resume.
  private func cancelDeferredPause() {
    if case .scheduled(let task, _) = deferredPause {
      task.cancel()
      deferredPause = .idle
    }
  }

  /// Schedules a deferred pause, replacing any in-flight one. The task
  /// sleeps for `pauseDebounce`, re-checks intent and player state on
  /// wake, and either issues the libVLC pause (transitioning to
  /// `.issued`) or exits cleanly (transitioning back to `.idle`).
  private func scheduleDeferredPause() {
    cancelDeferredPause()

    let generation = DeferredPauseState.nextGeneration(after: deferredPause)
    let debounce = pauseDebounce
    let task = Task { @MainActor [weak self] in
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
        guard !Task.isCancelled, currentDeferredPauseGeneration == generation, !pipPlaybackActive else { return }

        switch player.state {
        case .playing:
          if playbackDriver.pause() {
            deferredPause = .issued
            return
          }
          continue
        case .opening, .buffering:
          // Avoid pausing libVLC while it is still stabilizing input state.
          // Keep waiting unless AVKit changes its mind first.
          continue
        default:
          deferredPause = .idle
          return
        }
      }
    }
    deferredPause = .scheduled(task: task, generation: generation)
  }

  /// The generation id of an in-flight scheduled pause, or 0 if no
  /// task is currently scheduled. Used by the deferred-pause loop to
  /// detect when its scheduling slot has been replaced.
  private var currentDeferredPauseGeneration: UInt64 {
    if case .scheduled(_, let generation) = deferredPause { generation } else { 0 }
  }

  /// Clears the `.issued` flag without cancelling a scheduled pause.
  /// Used when an external event (the user pressing play, the player
  /// settling into `.playing` on its own) makes the PiP-issued pause
  /// obsolete but we don't want to disturb a still-pending schedule.
  private func clearIssuedPauseFlag() {
    if case .issued = deferredPause {
      deferredPause = .idle
    }
  }

  /// Returns whether PiP needs libVLC to resume, and whether the
  /// playback driver accepted the resume request. Checks both the
  /// `.issued` state (PiP actually paused libVLC) and the player's
  /// own resume hint.
  private func requestResumeIfNeeded() -> (needed: Bool, accepted: Bool) {
    let pipIssuedPause = if case .issued = deferredPause { true } else { false }
    let shouldResume = pipIssuedPause || playbackDriver.shouldResume()
    if pipIssuedPause {
      deferredPause = .idle
    }
    guard shouldResume else { return (needed: false, accepted: false) }
    return (needed: true, accepted: playbackDriver.resume())
  }

  // MARK: - State Observation

  /// Drives the control timebase and PiP UI from player events.
  ///
  /// The shape below matches `Player.startEventConsumer`: subscribe to
  /// `player.events` (the same broadcaster that drives `Player`'s own
  /// `@Observable` state), pull events via `for await`, and bind `self`
  /// strongly *inside* the loop body where the binding lifetime is a
  /// single iteration. The implicit suspension between events keeps only
  /// a weak reference in scope, so the observer task never prevents the
  /// controller from deinitializing.
  private func startStateObserver() {
    let events = player.events
    let initialActive = player.isPlaybackRequestedActive
    let initialNativeActive = player.isActive
    pipPlaybackActive = initialActive
    syncTimebase(playing: initialNativeActive)

    stateObserverTask = Task { @MainActor [weak self] in
      var wasActive = initialNativeActive
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
          let didAcceptNativeState = handleObservedPlaybackActivity(active)

          if didAcceptNativeState {
            syncTimebase(playing: active)
          }

          if didAcceptNativeState, active {
            // Player is now actively playing — any prior PiP-issued
            // pause has been superseded by the user's intent.
            clearIssuedPauseFlag()
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
          if active, let tb = controlTimebase {
            CMTimebaseSetRate(tb, rate: Float64(rate))
          }
        }

        // Duration became known or changed: re-query timeRange.
        if durationMs != lastDurationMs {
          lastDurationMs = durationMs
          invalidatePictureInPicturePlaybackState()
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

  private func startPlaybackIntentObserver() {
    let intents = player.playbackIntentEvents
    playbackIntentObserverTask = Task { @MainActor [weak self] in
      for await active in intents {
        guard let self else { return }
        handlePlaybackIntentChanged(active)
      }
    }
  }

  private func handlePlaybackIntentChanged(_ active: Bool) {
    if let pendingPiPPlaybackState, pendingPiPPlaybackState != active {
      self.pendingPiPPlaybackState = active
    }
    if pipPlaybackActive != active {
      pipPlaybackActive = active
    }
    if active {
      // Active intent supersedes any deferred pause — cancel the
      // scheduled task AND drop the `.issued` flag explicitly. The
      // user/external control has just told us to play; PiP's own
      // pause attempt is no longer relevant.
      cancelDeferredPause()
      clearIssuedPauseFlag()
    }
    // Playback intent drives the PiP button state, but the display
    // timebase must follow native playback. If libVLC has not actually
    // paused yet, stopping this timebase freezes video while audio keeps
    // running.
    syncTimebase(playing: player.isActive)
    invalidatePictureInPicturePlaybackState()
  }

  func handleSetPlaying(_ playing: Bool) {
    cancelDeferredPause()

    // Set immediately so isPlaybackPaused returns the correct value
    // when PiP queries it right after this call (before VLC catches up).
    pipPlaybackActive = playing
    pendingPiPPlaybackState = playing

    if playing {
      playbackDriver.cancelPendingPause()
      let resumeRequest = requestResumeIfNeeded()
      if resumeRequest.needed, !resumeRequest.accepted {
        pendingPiPPlaybackState = nil
        player.setPlaybackIntentFromExternalControl(player.isActive)
        pipPlaybackActive = player.isPlaybackRequestedActive
      } else if player.isActive, !resumeRequest.needed {
        player.setPlaybackIntentFromExternalControl(true)
        pendingPiPPlaybackState = nil
      } else {
        player.setPlaybackIntentFromExternalControl(true)
      }
    } else {
      player.setPlaybackIntentFromExternalControl(false)
      scheduleDeferredPause()
      if !player.isActive {
        pendingPiPPlaybackState = nil
      }
    }

    syncTimebase(playing: player.isActive)
    invalidatePictureInPicturePlaybackState()
  }

  @discardableResult
  private func handleObservedPlaybackActivity(_ active: Bool) -> Bool {
    if let pendingPiPPlaybackState {
      if active == pendingPiPPlaybackState {
        self.pendingPiPPlaybackState = nil
        if pipPlaybackActive != active {
          pipPlaybackActive = active
        }
        invalidatePictureInPicturePlaybackState()
        return true
      }

      switch player.state {
      case .idle, .stopped, .stopping, .error:
        self.pendingPiPPlaybackState = nil
        if pipPlaybackActive != false {
          pipPlaybackActive = false
          invalidatePictureInPicturePlaybackState()
        }
        return true
      default:
        break
      }
      return false
    }

    // Only update pipPlaybackActive and notify PiP for VLC-initiated
    // changes (end-of-media, error, or external app controls). For
    // PiP-initiated changes (from setPlaying), the pending state above
    // keeps the UI stable while libVLC catches up.
    if active != pipPlaybackActive {
      pipPlaybackActive = active
      invalidatePictureInPicturePlaybackState()
    }
    return true
  }

  func syncPlaybackStateForPictureInPicture() {
    guard pendingPiPPlaybackState == nil else { return }
    let active = player.isPlaybackRequestedActive
    if pipPlaybackActive != active {
      pipPlaybackActive = active
    }
    if active {
      clearIssuedPauseFlag()
    }
    syncTimebase(playing: player.isActive)
  }

  #if os(macOS)
  func handleNativePictureInPictureReady() {
    updatePiPPossible(nativeBackend?.isPossible == true)
  }

  func handleNativePictureInPictureActiveChanged(_ isActive: Bool) {
    updatePiPActive(isActive)
  }

  func handleNativePictureInPictureSetPlaying(_ playing: Bool) {
    handleSetPlaying(playing)
  }
  #endif

  func handleRenderSizeTransition(_ size: CMVideoDimensions) {
    #if os(macOS)
    guard nativeBackend == nil else { return }
    renderer.setRenderSize(size)
    renderer.flushDisplayLayer()
    #else
    _ = size
    #endif
  }

  func handleSkip(
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
      CMTimebaseSetRate(tb, rate: player.isActive ? Float64(player.rate) : 0.0)
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

  func _skipByIntervalForTesting(_ skipInterval: CMTime) {
    handleSkip(by: skipInterval) {}
  }

  func _renderSizeForTesting() -> CMVideoDimensions? {
    renderer.state.withLock { $0.renderSize }
  }
}

#endif
