// swiftlint:disable file_length
#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
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
/// `PiPController` behind a single SwiftUI view. On iOS that view uses
/// libVLC's native drawable PiP integration. On macOS it owns VLC's
/// native drawable container for inline playback; its native PiP start
/// path is disabled unless the `PrivateMacOSPiP` SPI opt-in is enabled.
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
  /// the PiP panel. SwiftVLC therefore disables the native macOS PiP
  /// backend by default instead of loading a private framework implicitly.
  ///
  /// Set this to `true` only when your distribution channel accepts
  /// private API use. With the flag `false`, the native macOS backend
  /// used by ``PiPVideoView`` reports `PiPController.isPossible == false`
  /// and `start()` is a no-op. iOS PiP is unaffected (it uses only
  /// public AVKit).
  ///
  /// This is intentionally SPI, not stable public API. It exists for
  /// non-App-Store distributions that deliberately accept private
  /// framework risk, and it may change or disappear outside SwiftVLC's
  /// public semantic-versioning contract.
  ///
  /// Read-write at any time; takes effect on the next backend
  /// `refreshPossible()` (each `attach`/`start` call).
  @_spi(PrivateMacOSPiP)
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
    /// Relative rather than absolute: see ``PiPController/performSkip(on:by:)``
    /// for why the interval AVKit requested is preserved instead of being
    /// converted into a target.
    let skip: @MainActor (CMTime) -> SkipOutcome

    static func live(player: Player) -> Self {
      Self(
        pause: { player.issuePause() },
        resume: { player.issueResume() },
        cancelPendingPause: { player.cancelPendingPause() },
        shouldResume: { player.shouldResumeForExternalPlayRequest },
        skip: { PiPController.performSkip(on: player, by: $0) }
      )
    }
  }

  @ObservationIgnored
  let player: Player
  @ObservationIgnored
  let playbackDriver: PlaybackDriver
  @ObservationIgnored
  private let pauseDebounce: Duration
  @ObservationIgnored
  let renderer: PixelBufferRenderer
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
  nonisolated let playbackDelegateProxy: PiPPlaybackDelegateProxy
  @ObservationIgnored
  var pipController: AVPictureInPictureController?
  @ObservationIgnored
  private var callbackRegistration: DirectPiPVideoCallbackRegistration?
  @ObservationIgnored
  var controlTimebase: CMTimebase? {
    didSet { refreshCallbackSnapshot() }
  }

  /// What AVKit's synchronous callbacks read instead of blocking on the main
  /// actor. See ``PiPCallbackSnapshot``.
  @ObservationIgnored
  nonisolated let callbackSnapshot = Mutex(PiPCallbackSnapshot())
  @ObservationIgnored
  var stateObserverTask: Task<Void, Never>?
  /// The state observer's second subscription. See ``startStateObserver()``
  /// for why it needs one per lane rather than one merged stream.
  @ObservationIgnored
  var timingObserverTask: Task<Void, Never>?
  /// The state observer's rolling view of duration and seekability.
  ///
  /// Owned by the controller rather than by an observer task because both lane
  /// tasks feed it. Both are `@MainActor`, so they serialize on this actor and
  /// interleave between events rather than racing within one.
  @ObservationIgnored
  var playbackStateObservation = PlaybackStateObservationState(duration: nil, isSeekable: false)
  /// Last native-active and rate values the observer acted on, for the same
  /// reason: the comparison has to survive across events from either lane.
  @ObservationIgnored
  var lastObservedNativeActive = false
  @ObservationIgnored
  var lastObservedRate: Float = 1.0
  @ObservationIgnored
  private var playbackIntentObserverTask: Task<Void, Never>?
  @ObservationIgnored
  private var cadenceObserverTask: Task<Void, Never>?
  @ObservationIgnored
  private var possibleObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var activeObservation: NSKeyValueObservation?
  #if os(iOS)
  /// Internal, not private: the validation-harness SPI in
  /// PiPController+Validation.swift probes the backend's wiring.
  @ObservationIgnored
  var nativeBackend: IOSNativePiPBackend?
  #endif
  #if os(macOS)
  @ObservationIgnored
  var nativeBackend: MacNativePiPBackend?
  #endif

  /// Whether AVKit may start PiP automatically when the app moves to
  /// the background while this controller's video is playing inline.
  /// Set by ``PiPVideoView``'s `startsAutomaticallyFromInline` knob;
  /// the direct public ``init(player:)`` path uses `true`.
  @ObservationIgnored
  let startsAutomaticallyFromInline: Bool

  /// Whether this controller configures and activates the shared
  /// `AVAudioSession` (iOS only). Set by ``PiPVideoView``'s
  /// `managesAudioSession` knob; the direct public ``init(player:)``
  /// path uses `true`. When `true`, the
  /// `.playback` category is set at init but `setActive(true)` is
  /// deferred to ``start()`` or an active-playback signal. Direct
  /// controller construction and inactive native-view construction do
  /// not take audio focus. A native view adopting a Player whose playback
  /// intent is already active activates immediately so automatic PiP cannot
  /// start before the managed session is ready. When `false`, the session
  /// is never touched.
  @ObservationIgnored
  let managesAudioSession: Bool

  /// Operation used by the deferred audio-session activation state machine.
  /// The native iOS initializer accepts an override so lifecycle ordering and
  /// retry behavior can be proven without depending on process-wide audio
  /// state. Every public/direct initializer uses the live AVAudioSession
  /// operation.
  @ObservationIgnored
  let audioSessionActivation: @MainActor () throws -> Void

  /// Whether the deferred `AVAudioSession.setActive(true)` has been
  /// issued. One-shot per controller; see ``managesAudioSession``.
  @ObservationIgnored
  var hasActivatedAudioSession = false

  /// Notification tokens for the managed session's disruption observers.
  /// Empty when ``managesAudioSession`` is `false` — nothing is observed
  /// because nothing may be changed. See `startAudioSessionObservers()`.
  @ObservationIgnored
  var audioSessionObservers: [any NSObjectProtocol] = []

  /// Broadcasts ``PiPEvent``s to every ``pipEvents`` subscriber.
  /// Terminated in deinit so subscribers' streams finish with the
  /// controller.
  @ObservationIgnored
  let pipEventBroadcaster = Broadcaster<PiPEvent>()
  @ObservationIgnored
  let pipEventEnvelopeBroadcaster = Broadcaster<PiPEventEnvelope>()
  @ObservationIgnored
  let pipSnapshotBroadcaster = Broadcaster<PiPSnapshot>()
  @ObservationIgnored
  private var pipSnapshotRevision: UInt64 = 0
  /// Advances every time a new `AVPictureInPictureController` is installed, so
  /// a snapshot can say which controller its flags describe and a late callback
  /// from a replaced one can be told apart from a current one.
  @ObservationIgnored
  private(set) var pipControllerGeneration: UInt64 = 0
  /// Monotonic identity for start attempts within this controller. Controller
  /// generation alone cannot order two overlapping requests issued to the
  /// same AVKit controller.
  @ObservationIgnored
  var pipLifecycleSequence: UInt64 = 0
  /// Identity captured when the current PiP lifecycle began. Kept until its
  /// terminal `didStop`, so a delayed callback remains attributable after the
  /// player has already adopted another media.
  @ObservationIgnored
  var pipLifecycleAttribution: PiPLifecycleAttribution?
  /// Failed starts can each be followed by a trailing stop after newer starts
  /// have already been accepted. Keep their identities and stop reasons in
  /// accepted-start order outside the current lifecycle, so consuming an old
  /// stop cannot relabel or clear a retry. A later terminal start outcome
  /// retires only older failures for which AVKit never promised a stop.
  @ObservationIgnored
  var failedPiPLifecycles: [FailedPiPLifecycle] = []
  /// A start accepted while an older lifecycle is still waiting for its stop.
  /// Promoted only after that stop is consumed.
  @ObservationIgnored
  var queuedPiPStartAttribution: PiPLifecycleAttribution?
  /// Which part of the attributed PiP lifecycle is in flight. This prevents a
  /// redundant accepted start from stealing an active lifecycle while still
  /// allowing a fresh request after a terminal start failure.
  @ObservationIgnored
  var pipLifecycleAttributionPhase: PiPLifecycleAttributionPhase = .idle

  struct PiPLifecycleAttribution {
    let mediaGeneration: PlaybackGeneration
    let controllerGeneration: UInt64
    let sequence: UInt64
  }

  struct FailedPiPLifecycle {
    let attribution: PiPLifecycleAttribution
    let stopReason: PiPStopReason
    var willStopObserved = false
  }

  enum PiPLifecycleAttributionPhase: Equatable {
    case idle
    case awaitingStart
    case started
    case stopping
  }

  /// The best-known reason for an in-flight PiP stop, recorded by the
  /// first discriminating signal (restore callback, start failure,
  /// programmatic ``stop()``) and consumed by the stop delegate
  /// callbacks. `nil` when no discriminating signal has been observed;
  /// see ``PiPController/pipEvents`` for the resolution rules.
  @ObservationIgnored
  var pendingStopReason: PiPStopReason?

  /// Playback state as PiP sees it. Updated synchronously in
  /// `setPlaying` (PiP-initiated) and by the observer (VLC-initiated,
  /// e.g. end-of-media). `isPlaybackPaused` reads this directly, so
  /// the answer is consistent without waiting for VLC's async state
  /// transitions. PiP queries state immediately after calling
  /// `setPlaying` and would otherwise see stale values.
  @ObservationIgnored
  var pipPlaybackActive: Bool = false {
    didSet { refreshCallbackSnapshot() }
  }

  /// Desired playback state from the PiP controls while libVLC is still
  /// catching up. During this window player events can still report the
  /// previous state, so the event observer must not overwrite
  /// `pipPlaybackActive` until native playback reaches the requested
  /// state or exits playback entirely.
  @ObservationIgnored
  var pendingPiPPlaybackState: Bool?

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

  /// How a deferred PiP pause finished.
  ///
  /// Not surfaced on ``PiPEvent`` because that is a public non-frozen enum and
  /// adding a case would be source-breaking for exhaustive switches. The
  /// user-visible half of the outcome is reconciled onto
  /// ``Player/isPlaybackRequestedActive`` instead, which is already
  /// observable.
  enum DeferredPauseOutcome: Equatable {
    /// libVLC accepted the pause.
    case issued
    /// Superseded, or the session left a pausable state before it could be
    /// issued.
    case cancelled
    /// The input never became pausable within the retry bound. Playback keeps
    /// running and the published intent is reconciled back to active.
    case rejected
  }

  /// The outcome of the most recent deferred pause, or `nil` while one is in
  /// flight. Internal rather than public: it exists so the bound and the
  /// reconciliation are assertable.
  @ObservationIgnored
  private(set) var deferredPauseOutcome: DeferredPauseOutcome?

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
  var lastSkipTimestamp: CFAbsoluteTime = 0

  /// Whether PiP can be started right now.
  ///
  /// Returns `false` on devices or simulators that don't support PiP,
  /// and briefly after initialization until the system has validated
  /// the layer. Observe this before enabling a "Picture-in-Picture"
  /// button in your UI.
  public private(set) var isPossible: Bool = false

  /// Whether a PiP window is currently visible.
  public private(set) var isActive: Bool = false

  /// Invoked when the user taps the PiP window's **restore** affordance
  /// (the "return to app" control), as opposed to the **close** (X)
  /// button.
  ///
  /// Use this to bring your full-screen player UI back on screen when the
  /// user wants to keep watching in the app. The closure receives a
  /// completion handler that you **must** call once your interface has
  /// finished restoring, so AVKit can dismiss the PiP window cleanly. Pass
  /// `true` if the UI was restored successfully, or `false` if you could
  /// not bring it back; the value is forwarded to AVKit.
  ///
  /// This is *not* called when PiP stops via the close button, an
  /// end-of-media stop, or a programmatic ``stop()`` — those paths flip
  /// ``isActive`` to `false` and emit ``PiPEvent/didStop(reason:)``
  /// with their own ``PiPStopReason``. That distinction is the whole
  /// point: observe ``isActive`` or ``pipEvents`` for "PiP ended", and
  /// use this hook for "PiP ended *and the user asked to come back*".
  ///
  /// If this is `nil`, restoration completes immediately.
  ///
  /// - Note: iOS sample-buffer PiP only. On platforms/backends without a
  ///   restore affordance this is never called.
  @ObservationIgnored
  public var onRestoreUserInterface: (@MainActor (@escaping @MainActor (Bool) -> Void) -> Void)?

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
    startsAutomaticallyFromInline = true
    managesAudioSession = true
    audioSessionActivation = Self.liveAudioSessionActivation
    displayLayer = AVSampleBufferDisplayLayer()
    renderer = PixelBufferRenderer(displayLayer: displayLayer)
    playbackDelegateProxy = PiPPlaybackDelegateProxy()

    super.init()
    // Seeded here, not on first change: a controller whose flags never move
    // would otherwise leave `pipSnapshots` with nothing to replay.
    publishPiPSnapshot()

    playbackDelegateProxy.owner = self
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    configureAudioSession()
    startAudioSessionObserversIfManaged()
    setupControlTimebase()
    attachCallbacks()
    setupPiPController()
    startStateObserver()
    startPlaybackIntentObserver()
    player.registerNativeHandleSnapshotObserver(self)
    startCadenceObserver()
  }

  #if os(iOS)
  init(
    player: Player,
    nativeBackend: IOSNativePiPBackend,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true,
    audioSessionActivation: (@MainActor () throws -> Void)? = nil
  ) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
    self.audioSessionActivation = audioSessionActivation
      ?? Self.liveAudioSessionActivation
    displayLayer = AVSampleBufferDisplayLayer()
    renderer = PixelBufferRenderer(displayLayer: displayLayer)
    playbackDelegateProxy = PiPPlaybackDelegateProxy()
    self.nativeBackend = nativeBackend

    super.init()
    pipControllerGeneration = 1
    // Seeded here, not on first change: a controller whose flags never move
    // would otherwise leave `pipSnapshots` with nothing to replay.
    publishPiPSnapshot()

    playbackDelegateProxy.owner = self
    configureAudioSession()
    startAudioSessionObserversIfManaged()
    nativeBackend.setStartsAutomaticallyFromInline(startsAutomaticallyFromInline)

    // The native AVPictureInPictureController already belongs to the open
    // vout and may auto-start as soon as the app backgrounds. Unlike generic
    // direct-controller construction, adopting that live route must honor an
    // already-active playback intent before we expose this controller as the
    // backend owner. The operation remains deferred for inactive players.
    if player.isPlaybackRequestedActive {
      activateAudioSessionIfNeeded()
    }

    nativeBackend.owner = self
    // A same-player SwiftUI recreation can preserve the attachment/backend
    // while no PiPController owns it. Any seekability event in that interval
    // is intentionally rejected by the owner gate, so resample the Player at
    // the exact point the successor claims the current attachment.
    nativeBackend.reconcileRequiresLinearPlayback(ifOwnedBy: self)
    updatePiPPossible(nativeBackend.isPossible)
    updatePiPActive(nativeBackend.isActive)
    if nativeBackend.isActive {
      adoptActivePiPLifecycleAttribution(
        mediaGeneration: nativeBackend.activeMediaGeneration
      )
    }
    startStateObserver()
    startPlaybackIntentObserver()
    player.registerNativeHandleSnapshotObserver(self)
  }
  #endif

  #if os(macOS)
  init(
    player: Player,
    nativeBackend: MacNativePiPBackend,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true
  ) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
    audioSessionActivation = Self.liveAudioSessionActivation
    displayLayer = AVSampleBufferDisplayLayer()
    renderer = PixelBufferRenderer(displayLayer: displayLayer)
    playbackDelegateProxy = PiPPlaybackDelegateProxy()
    self.nativeBackend = nativeBackend

    super.init()
    pipControllerGeneration = 1
    // Seeded here, not on first change: a controller whose flags never move
    // would otherwise leave `pipSnapshots` with nothing to replay.
    publishPiPSnapshot()

    playbackDelegateProxy.owner = self
    nativeBackend.owner = self
    updatePiPPossible(nativeBackend.isPossible)
    updatePiPActive(nativeBackend.isActive)
    if nativeBackend.isActive {
      adoptActivePiPLifecycleAttribution(
        mediaGeneration: nativeBackend.activeMediaGeneration
      )
    }
    startStateObserver()
    startPlaybackIntentObserver()
    player.registerNativeHandleSnapshotObserver(self)
  }
  #endif

  init(
    player: Player,
    playbackDriver: PlaybackDriver,
    pauseDebounce: Duration,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true
  ) {
    self.player = player
    self.playbackDriver = playbackDriver
    self.pauseDebounce = pauseDebounce
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
    audioSessionActivation = Self.liveAudioSessionActivation
    displayLayer = AVSampleBufferDisplayLayer()
    renderer = PixelBufferRenderer(displayLayer: displayLayer)
    playbackDelegateProxy = PiPPlaybackDelegateProxy()

    super.init()
    // Seeded here, not on first change: a controller whose flags never move
    // would otherwise leave `pipSnapshots` with nothing to replay.
    publishPiPSnapshot()

    playbackDelegateProxy.owner = self
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    configureAudioSession()
    startAudioSessionObserversIfManaged()
    setupControlTimebase()
    attachCallbacks()
    setupPiPController()
    startStateObserver()
    startPlaybackIntentObserver()
    player.registerNativeHandleSnapshotObserver(self)
  }

  isolated deinit {
    pipEventBroadcaster.terminate()
    pipEventEnvelopeBroadcaster.terminate()
    pipSnapshotBroadcaster.terminate()
    cancelDeferredPause()
    stateObserverTask?.cancel()
    timingObserverTask?.cancel()
    playbackIntentObserverTask?.cancel()
    cadenceObserverTask?.cancel()
    possibleObservation = nil
    activeObservation = nil
    stopAudioSessionObserversIfManaged()
    // No explicit native-backend relinquish: the backend holds its `owner`
    // weakly, so ARC clears the back-reference as this controller is torn
    // down. A player swap (`updateUIView`/`updateNSView`) reassigns `owner`
    // to the successor controller before this one's deinit runs, so the
    // successor's claim is preserved without us touching it here.
    pipController?.delegate = nil
    playbackDelegateProxy.owner = nil
    // Stop any in-flight AVKit query from interrogating a handle that is
    // about to be released. Cleared before the relinquish below, so the
    // window where a callback could see a dead pointer never opens.
    player.unregisterNativeHandleSnapshotObserver(self)
    invalidateCallbackSnapshot()
    renderer.setDisplayLayer(nil)
    renderer.setTimebase(nil)
    if let callbackRegistration {
      player.relinquishDirectPiPVideoCallbacks(callbackRegistration)
    }
  }

  // MARK: - Public API

  /// Starts Picture-in-Picture if possible and media is loaded.
  ///
  /// The returned ``PiPStartResult`` describes only whether the request was
  /// issued. Previously every early exit returned silently, so a caller could
  /// not tell a request that reached AVKit from one that never left the
  /// controller — and therefore could not decide whether to fall back to
  /// full-screen playback. Asynchronous AVKit failure after an accepted start
  /// stays where it belongs, on ``pipEventEnvelopes`` (or the compatibility
  /// ``pipEvents`` stream when generation attribution is not needed).
  @discardableResult
  public func start() -> PiPStartResult {
    guard player.currentMedia != nil else { return .noMedia }
    #if os(iOS)
    if let nativeBackend {
      // Do not take audio focus for a request the native controller cannot
      // perform. The backend is still asked either way, both for its one-time
      // vout diagnostic and because its answer is the authoritative one —
      // substituting `.notPossible` here would report the controller's guess
      // over the backend's own finding, and would hide a `.noMedia` the
      // backend can see and this layer cannot.
      if nativeBackend.isPossible {
        activateAudioSessionIfNeeded()
      }
      return noteAcceptedPiPStartRequest(nativeBackend.start())
    }
    #endif
    #if os(macOS)
    if let nativeBackend {
      return noteAcceptedPiPStartRequest(nativeBackend.start())
    }
    #endif
    guard let pipController else { return .backendUnavailable }
    guard isPossible else { return .notPossible }
    activateAudioSessionIfNeeded()
    pipController.startPictureInPicture()
    return noteAcceptedPiPStartRequest(.accepted)
  }

  /// Stops Picture-in-Picture.
  ///
  /// A stop initiated through this method is reported on
  /// ``pipEvents`` with ``PiPStopReason/unknown``: AVKit gives a
  /// programmatic stop no discriminating delegate signal, so SwiftVLC
  /// does not guess a richer reason for it.
  public func stop() {
    // Recorded unconditionally: between AVKit beginning the start
    // animation and the didStart callback, `isActive` is still false,
    // and a stop issued in that window would otherwise be reported as
    // the user's close tap. If no lifecycle was actually in flight, the next
    // accepted start (or an automatic willStart/didStart) clears it.
    notePendingStopReason(.unknown)
    #if os(iOS)
    if let nativeBackend {
      nativeBackend.stop()
      return
    }
    #endif
    #if os(macOS)
    if let nativeBackend {
      nativeBackend.stop()
      return
    }
    #endif
    pipController?.stopPictureInPicture()
  }

  /// Toggles Picture-in-Picture on/off.
  /// - Returns: the ``PiPStartResult`` when this call took the start branch,
  ///   or `nil` when it stopped an active session. A caller that wants to fall
  ///   back on a refused start needs to distinguish "I tried to start and it
  ///   was refused" from "I stopped"; collapsing both to `Void` made that
  ///   impossible.
  @discardableResult
  public func toggle() -> PiPStartResult? {
    if isActive {
      stop()
      return nil
    }
    return start()
  }

  // MARK: - Setup

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
    let registration = DirectPiPVideoCallbackRegistration(renderer: renderer)
    callbackRegistration = registration
    player.claimDirectPiPVideoCallbacks(registration)
    // Publish the handle the AVKit callback threads will interrogate. Until
    // this runs the snapshot reports "not attached" and the synchronous
    // queries answer with their stable defaults.
    refreshCallbackSnapshot()
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
    controller.requiresLinearPlayback = !player.isSeekable
    #if os(iOS)
    controller.canStartPictureInPictureAutomaticallyFromInline = startsAutomaticallyFromInline
    #endif
    pipControllerGeneration &+= 1
    clearPiPLifecycleAttribution()
    pipController = controller
    publishPiPSnapshot()
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
      let identity = ObjectIdentifier(controller)
      Task { @MainActor [weak self] in
        // The hop means the controller can be replaced before this runs.
        // Without the identity check a flag from the outgoing controller
        // would be applied to the incoming one.
        guard let self, isCurrentAVController(identity) else { return }
        updatePiPPossible(isPossible)
      }
    }

    activeObservation = controller.observe(
      \.isPictureInPictureActive,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isActive = controller.isPictureInPictureActive
      let identity = ObjectIdentifier(controller)
      Task { @MainActor [weak self] in
        guard let self, isCurrentAVController(identity) else { return }
        updatePiPActive(isActive)
      }
    }
  }

  /// Whether the identified controller is the one currently installed.
  ///
  /// Every AVKit signal reaches the main actor through a hop, so a controller
  /// replaced in the meantime can still deliver. Its state describes a session
  /// that is over.
  ///
  /// Takes an `ObjectIdentifier` rather than the controller itself:
  /// `AVPictureInPictureController` is not `Sendable`, so it cannot cross the
  /// hop, while its identity can.
  ///
  /// `nil` never matches. With no controller installed there is nothing for a
  /// callback to be current with respect to.
  func isCurrentAVController(_ identity: ObjectIdentifier) -> Bool {
    pipController.map(ObjectIdentifier.init) == identity
  }

  func updatePiPPossible(_ isPossible: Bool) {
    guard self.isPossible != isPossible else { return }
    self.isPossible = isPossible
    publishPiPSnapshot()
  }

  func updatePiPActive(_ isActive: Bool) {
    guard self.isActive != isActive else { return }
    self.isActive = isActive
    publishPiPSnapshot()
  }

  /// Publishes the current flags as one value.
  ///
  /// Called from both funnels rather than either alone: the two flags move
  /// independently, so publishing from one would leave the snapshot describing
  /// a pair that was never simultaneously true.
  func publishPiPSnapshot() {
    pipSnapshotRevision &+= 1
    pipSnapshotBroadcaster.broadcast(
      PiPSnapshot(
        isActive: isActive,
        isPossible: isPossible,
        mediaGeneration: player.generation,
        controllerGeneration: pipControllerGeneration,
        revision: pipSnapshotRevision
      )
    )
  }

  func applyObservedPlaybackStateUpdate(_ update: PlaybackStateUpdate) {
    Self.applyPlaybackStateUpdate(
      update,
      setRequiresLinearPlayback: { setRequiresLinearPlayback($0) },
      invalidatePlaybackState: { invalidatePictureInPicturePlaybackState() }
    )
  }

  private func setRequiresLinearPlayback(_ requiresLinearPlayback: Bool) {
    #if os(iOS)
    if let nativeBackend {
      nativeBackend.setRequiresLinearPlayback(
        requiresLinearPlayback,
        ifOwnedBy: self
      )
      return
    }
    #endif
    pipController?.requiresLinearPlayback = requiresLinearPlayback
  }

  func invalidatePictureInPicturePlaybackState() {
    #if os(iOS)
    if let nativeBackend {
      nativeBackend.invalidatePlaybackState(ifOwnedBy: self)
      return
    }
    #endif
    #if os(macOS)
    if let nativeBackend {
      nativeBackend.invalidatePlaybackState()
      return
    }
    #endif
    pipController?.invalidatePlaybackState()
  }

  /// Cancels any in-flight scheduled pause. This **only** cancels the
  /// `.scheduled` task; an already-`.issued` pause is preserved —
  /// `requestResumeIfNeeded` reads it to decide whether to issue a libVLC
  /// resume.
  private func cancelDeferredPause() {
    if case .scheduled(let task, _) = deferredPause {
      task.cancel()
      deferredPause = .idle
      // A pause that is cancelled before it can be issued is a cancellation,
      // whichever caller cancelled it. `scheduleDeferredPause` clears this
      // again straight afterwards, so a supersede reads as "in flight"
      // rather than as the superseded attempt's outcome.
      deferredPauseOutcome = .cancelled
    }
  }

  /// Schedules a deferred pause, replacing any in-flight one. The task
  /// sleeps for `pauseDebounce`, re-checks intent and player state on
  /// wake, and either issues the libVLC pause (transitioning to
  /// `.issued`) or exits cleanly (transitioning back to `.idle`).
  private func scheduleDeferredPause() {
    cancelDeferredPause()
    // A new attempt is in flight and has not finished yet. Without this the
    // previous attempt's outcome would stay readable for the whole debounce,
    // so a reader could not tell a settled result from a stale one.
    deferredPauseOutcome = nil

    let generation = DeferredPauseState.nextGeneration(after: deferredPause)
    let debounce = pauseDebounce
    let task = Task { @MainActor [weak self] in
      var attemptsRemaining = Self.maxDeferredPauseAttempts
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: debounce)
        } catch {
          return
        }

        // Bind `self` after the suspension so the observer only keeps the
        // controller alive while it is deciding whether to issue the pause.
        guard let self else { return }
        guard !Task.isCancelled, currentDeferredPauseGeneration == generation, !pipPlaybackActive else { return }

        switch player.state {
        case .playing:
          if playbackDriver.pause() {
            deferredPause = .issued
            deferredPauseOutcome = .issued
            return
          }
          // libVLC refused. Retry, but not forever.
          attemptsRemaining -= 1
        case .opening, .buffering:
          // Avoid pausing libVLC while it is still stabilizing input state.
          // Keep waiting unless AVKit changes its mind first — bounded, so an
          // input that never stabilizes cannot retry indefinitely.
          attemptsRemaining -= 1
        default:
          deferredPause = .idle
          deferredPauseOutcome = .cancelled
          return
        }

        if attemptsRemaining <= 0 {
          deferredPause = .idle
          settleUnpausableInput()
          return
        }
      }
    }
    deferredPause = .scheduled(task: task, generation: generation)
  }

  /// How many debounce intervals a deferred pause may retry before the input
  /// is treated as unpausable.
  ///
  /// At the default 250 ms debounce this is ten seconds — long enough for a
  /// slow network open to stabilize, short enough that a permanently
  /// unpausable input does not leave a paused UI over continuing playback
  /// indefinitely.
  static let maxDeferredPauseAttempts = 40

  /// Reconciles after a deferred pause has been abandoned.
  ///
  /// The input never became pausable, so playback is still running. The
  /// public intent was already published as inactive when PiP asked to pause;
  /// leaving it there would show paused controls over playing media — the
  /// visible half of this bug. Republish the truth on both surfaces.
  private func settleUnpausableInput() {
    deferredPauseOutcome = .rejected
    guard player.state.isActive else { return }
    player.setPlaybackIntentFromExternalControl(true)
    pipPlaybackActive = true
    invalidatePictureInPicturePlaybackState()
  }

  /// The generation id of an in-flight scheduled pause, or 0 if no
  /// task is currently scheduled. Used by the deferred-pause loop to
  /// detect when its scheduling slot has been replaced.
  private var currentDeferredPauseGeneration: UInt64 {
    if case .scheduled(_, let generation) = deferredPause {
      generation
    } else {
      0
    }
  }

  /// Clears the `.issued` flag without cancelling a scheduled pause.
  /// Used when an external event (the user pressing play, the player
  /// settling into `.playing` on its own) makes the PiP-issued pause
  /// obsolete but we don't want to disturb a still-pending schedule.
  func clearIssuedPauseFlag() {
    if case .issued = deferredPause {
      deferredPause = .idle
    }
  }

  /// Returns whether PiP needs libVLC to resume, and whether the
  /// playback driver accepted the resume request. Checks both the
  /// `.issued` state (PiP actually paused libVLC) and the player's
  /// own resume hint.
  private func requestResumeIfNeeded() -> (needed: Bool, accepted: Bool) {
    let pipIssuedPause = if case .issued = deferredPause {
      true
    } else {
      false
    }
    let shouldResume = pipIssuedPause || playbackDriver.shouldResume()
    if pipIssuedPause {
      deferredPause = .idle
    }
    guard shouldResume else { return (needed: false, accepted: false) }
    return (needed: true, accepted: playbackDriver.resume())
  }

  // MARK: - State Observation

  /// Keeps the renderer's frame cadence in step with the source.
  ///
  /// A *separate* subscription on the lossless control lane rather than a
  /// branch in the state observer. It was split off when that observer still
  /// read the mixed, newest-wins `events` stream, where a burst of clock
  /// samples under a main-actor stall could evict the very `tracksChanged`
  /// that reports a cadence change — leaving the renderer stamping the
  /// previous source's rate for the rest of the session.
  ///
  /// ``startStateObserver()`` now takes the control lane too, so that
  /// specific hazard is gone and this could fold into it. It stays separate
  /// because the concerns are unrelated: cadence needs only `tracksChanged`
  /// and `mediaChanged`, and keeping it out of the state observer's body
  /// means a change to one cannot perturb the other.
  ///
  /// Safe to run concurrently with the state observer because it shares no
  /// mutable state with it: it reads the track list and writes one
  /// lock-protected duration, and doing that twice for the same media is
  /// indistinguishable from doing it once.
  private func startCadenceObserver() {
    let events = player.controlEvents
    cadenceObserverTask = Task { @MainActor [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .tracksChanged, .mediaChanged:
          // Cadence is only knowable once the video track has been parsed, and
          // it changes on media replacement and on an adaptive representation
          // switch — both of which re-report tracks.
          renderer.setFrameDuration(Self.sourceFrameDuration(of: player))
        default:
          break
        }
      }
    }
  }

  private func startPlaybackIntentObserver() {
    // The transition stream intentionally has no current-value replay. Direct
    // construction therefore remains side-effect free; the native initializer
    // separately handles adoption of an already-active Player before backend
    // ownership is published. Later transitions activate through this loop.
    let intents = player.playbackIntentEvents
    playbackIntentObserverTask = Task { @MainActor [weak self] in
      for await active in intents {
        guard let self else { return }
        handlePlaybackIntentChanged(active)
      }
    }
  }

  private func handlePlaybackIntentChanged(_ active: Bool) {
    if active {
      activateAudioSessionIfNeeded()
    }
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
  func handleObservedPlaybackActivity(_ active: Bool) -> Bool {
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

  #if os(iOS) || os(macOS)
  func handleNativePictureInPictureReady() {
    updatePiPPossible(nativeBackend?.isPossible == true)
  }

  /// Mirrors the native backend's active flag and synthesizes the
  /// ``PiPEvent``s the backend can observe. libVLC owns the
  /// `AVPictureInPictureController` (and its delegate) on the native
  /// drawable path, so the only signal SwiftVLC sees is this active
  /// flip: `.didStart`/`.didStop` are synthesized from it, will/failed
  /// events never fire, and the stop reason degrades to
  /// ``PiPStopReason/unknown`` — including for stops caused by a
  /// native-handle replacement (player swap, renderer recast) tearing
  /// PiP down. See ``pipEvents``.
  func handleNativePictureInPictureActiveChanged(
    _ isActive: Bool,
    mediaGeneration: PlaybackGeneration? = nil,
    forceTransitionEvent: Bool = false,
    preservesCurrentLifecycle: Bool = false
  ) {
    #if os(iOS)
    if isActive {
      // Native auto-start does not deliver SwiftVLC's AVKit delegate
      // `willStart` callback. Retry here so a transient ownership-time audio
      // activation failure cannot leave an already-running PiP session
      // without the playback audio category/session.
      activateAudioSessionIfNeeded()
    }
    #endif
    let changed = self.isActive != isActive
    updatePiPActive(isActive)
    guard changed || forceTransitionEvent else { return }
    if preservesCurrentLifecycle {
      publishTransferredNativePiPEvent(
        isActive ? .didStart : .didStop(reason: .unknown),
        mediaGeneration: mediaGeneration
      )
      return
    }
    if isActive {
      publishPiPEvent(.didStart, mediaGeneration: mediaGeneration)
    } else {
      publishPiPEvent(.didStop(reason: .unknown), mediaGeneration: mediaGeneration)
      pendingStopReason = nil
    }
  }

  func handleNativePictureInPictureSetPlaying(_ playing: Bool) {
    handleSetPlaying(playing)
  }
  #endif

  /// Routes AVKit's PiP render size into the conversion target.
  ///
  /// iOS previously discarded this, so a PiP resize changed no work at all
  /// while macOS already honoured it — issue 93 criterion 2. There was no
  /// recorded reason for the asymmetry; it came in with a macOS-only change.
  ///
  /// `nativeBackend != nil` is still excluded: on that path libVLC owns the
  /// vout and the sample-buffer renderer is not what feeds the PiP window, so
  /// setting a render size would resize a surface nothing displays.
  func handleRenderSizeTransition(_ size: CMVideoDimensions) {
    #if os(iOS)
    guard nativeBackend == nil else { return }
    #endif
    // Flush only when the target actually moved. AVKit repeats this callback,
    // and flushing on a redundant one discards queued frames for nothing.
    guard renderer.setRenderSize(size) else { return }
    renderer.flushDisplayLayer()
  }

  func handleSkip(
    by skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    // Cancel any pending transient pause. Skip actions should not drive
    // libVLC through a pause → seek → resume cycle.
    cancelDeferredPause()

    // Reject an interval that cannot be expressed in libVLC's millisecond unit
    // here rather than inside the driver, so no driver — live or injected —
    // is ever handed one. AVKit has no contract preventing it from passing an
    // indefinite or infinite CMTime.
    guard Self.skipOffsetMilliseconds(skipInterval) != nil else {
      completionHandler()
      return
    }

    let outcome = playbackDriver.skip(skipInterval)

    // A refused skip leaves the timeline untouched. Moving the timebase to a
    // target the media never reached would put the transport controls ahead of
    // playback until the next native clock sample yanked them back.
    guard Self.skipMovedTimeline(outcome) else {
      completionHandler()
      return
    }

    lastSkipTimestamp = CFAbsoluteTimeGetCurrent()

    // Apple docs: "the control timebase should reflect the current
    // playback time and rate when the closure is invoked". Read it back from
    // the player rather than from a locally computed target: `jump(by:)` has
    // already published its own clamped estimate, and recomputing one here
    // could disagree with it.
    if let tb = controlTimebase {
      CMTimebaseSetTime(tb, time: CMTime(
        seconds: Double(player.currentTime.milliseconds) / 1000.0,
        preferredTimescale: 1000
      ))
      CMTimebaseSetRate(tb, rate: player.isActive ? Float64(player.rate) : 0.0)
    }

    completionHandler()
  }

  /// Sets the controlTimebase time to the player's current position.
  func syncTimebaseTime() {
    guard let tb = controlTimebase else { return }
    let t = player.currentTime
    let seconds = Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18
    CMTimebaseSetTime(tb, time: CMTime(seconds: seconds, preferredTimescale: 1000))
  }

  /// Updates the controlTimebase time and rate to match playback state.
  ///
  /// When `playing` is true the timebase tracks the player's current
  /// `rate` so PiP's scrubber animates at the real playback speed.
  func syncTimebase(playing: Bool) {
    guard let tb = controlTimebase else { return }
    syncTimebaseTime()
    CMTimebaseSetRate(tb, rate: playing ? Float64(player.rate) : 0.0)
  }
}

#endif
