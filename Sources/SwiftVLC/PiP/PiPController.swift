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
    struct PauseAttempt {
      let accepted: Bool
      let playbackControlRevision: UInt64?
    }

    /// `nil` follows the current media; a concrete value binds deferred work
    /// to the media generation that originally scheduled it.
    let pause: @MainActor (
      _ playbackGeneration: UInt64?,
      _ recordsPlaybackControlIntent: Bool
    ) -> PauseAttempt
    let resume: @MainActor (_ recordsPlaybackControlIntent: Bool) -> Bool
    let cancelPendingPause: @MainActor (
      _ playbackGeneration: UInt64?,
      _ playbackControlRevision: UInt64?,
      _ restoringPlaybackControlIntent: Player.DeferredPauseCommand
    ) -> Void
    let shouldResume: @MainActor () -> Bool
    /// Relative rather than absolute: see ``PiPController/performSkip(on:by:)``
    /// for why the interval AVKit requested is preserved instead of being
    /// converted into a target.
    let skip: @MainActor (CMTime) -> SkipRequest
    /// Starts playback that has ended or never began, which no resume can do.
    /// Returns `nil` when the player is in a session a resume applies to,
    /// otherwise whether playback was started. A driver without one treats
    /// every Play as a resume.
    var startStoppedPlayback: (@MainActor () -> Bool?)?

    static func live(player: Player) -> Self {
      Self(
        pause: {
          let revisionBeforePause = player.playbackControlIntentRevision
          let accepted = if $1 {
            player.issuePause(
              playbackGeneration: $0,
              recordsPlaybackControlIntent: true
            )
          } else {
            player.issueManagedAudioPause(playbackGeneration: $0)
          }
          return PauseAttempt(
            accepted: accepted,
            playbackControlRevision: $1 ? revisionBeforePause &+ 1 : nil
          )
        },
        resume: {
          $0
            ? player.issueResume(authorizesPlaybackAfterMediaServicesReset: true)
            : player.issueManagedAudioResume()
        },
        cancelPendingPause: {
          player.cancelPendingPause(
            playbackGeneration: $0,
            playbackControlRevision: $1,
            restoringPlaybackControlIntent: $2
          )
        },
        shouldResume: { player.shouldResumeForExternalPlayRequest },
        skip: { PiPController.performSkip(on: player, by: $0) },
        startStoppedPlayback: {
          guard player.state == .idle || player.state == .stopped else { return nil }
          return (try? player.play()) != nil
        }
      )
    }
  }

  @ObservationIgnored
  let player: Player
  @ObservationIgnored
  let playbackDriver: PlaybackDriver
  @ObservationIgnored
  let pauseDebounce: Duration
  #if DEBUG
  @ObservationIgnored
  var _deferredPauseRetryHookForTesting: (() -> Void)?
  #endif
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
  var callbackRegistration: DirectPiPVideoCallbackRegistration?
  @ObservationIgnored
  private var didInvalidateForLifecycleEnd = false
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
  /// Effective-rate resolutions use a dedicated provenance-bearing stream so
  /// they do not expand PlayerEvent's source-exhaustive public surface.
  @ObservationIgnored
  var effectivePlaybackRateObserverTask: Task<Void, Never>?
  /// The state observer's rolling view of duration and seekability.
  ///
  /// Owned by the controller rather than by an observer task because both lane
  /// tasks feed it. Both are `@MainActor`, so they serialize on this actor and
  /// interleave between events rather than racing within one.
  @ObservationIgnored
  var playbackStateObservation = PlaybackStateObservationState(duration: nil, isSeekable: false)
  /// Counts raw capability callbacks rejected by this controller's independent
  /// event subscriptions while the qualification suppression seam is active.
  @ObservationIgnored
  var playbackStateEventSuppression = PlaybackStateEventSuppression()
  /// Last native-active and rate values the observer acted on, for the same
  /// reason: the comparison has to survive across events from either lane.
  @ObservationIgnored
  var lastObservedNativeActive = false
  @ObservationIgnored
  var lastObservedRate: Float = 1.0
  @ObservationIgnored
  private var playbackIntentObserverTask: Task<Void, Never>?
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
  /// `AVAudioSession` (iOS only). Direct construction and the current
  /// ``PiPVideoView`` initializer inherit this value from the player's
  /// ``Player/appleAudioSessionPolicy``. The deprecated view initializer can
  /// preserve its pre-1.1 controller-local override without changing the
  /// instance policy used by bundled libVLC. When `true` on a library-managed
  /// instance, native broker acquisition configures `.playback` /
  /// `.moviePlayback` and activates as one serialized operation, deferred to
  /// ``start()`` or an active-playback signal. An application-managed native
  /// broker remains a no-op even if the legacy controller flag is `true`. Direct
  /// controller construction and inactive native-view construction do
  /// not take audio focus. A native view adopting a Player whose playback
  /// intent is already active activates immediately so automatic PiP cannot
  /// start before the managed session is ready. When `false`, this controller
  /// never touches the session; bundled libVLC continues to follow the
  /// instance policy.
  @ObservationIgnored
  let managesAudioSession: Bool

  /// Records an applied, source-compatible legacy PiP controller override that
  /// differs from the immutable instance policy. This makes the transitional
  /// split explicit and testable; it does not claim that bundled libVLC adopted
  /// the controller-local value.
  @ObservationIgnored
  let audioSessionPolicyDiagnostic: AppleAudioSessionPolicyDiagnostic?

  /// Optional operation used to test the deferred audio-session activation
  /// state machine without mutating process-wide audio state. Production
  /// controllers leave this nil and acquire the player's unique native broker
  /// lease instead.
  @ObservationIgnored
  let audioSessionActivation: (@MainActor () throws -> Void)?

  /// Whether the latest deferred `AVAudioSession.setActive(true)` succeeded.
  /// The latch is cleared after interruptions, media-services loss, and
  /// lifecycle suspension so recovery never trusts an invalid session.
  @ObservationIgnored
  var hasActivatedAudioSession = false

  /// Notification tokens for the managed session's disruption observers.
  /// Empty when ``managesAudioSession`` is `false` — nothing is observed
  /// because nothing may be changed. See `startAudioSessionObservers()`.
  @ObservationIgnored
  var audioSessionObservers: [any NSObjectProtocol] = []

  /// Delays the background-without-PiP decision long enough for AVKit's
  /// automatic PiP transition to settle. Cancelled when PiP becomes active or
  /// the app returns to the foreground.
  @ObservationIgnored
  var audioSessionBackgroundPauseTask: Task<Void, Never>?

  /// Tracks UIKit lifecycle independently of PiP activity. If PiP stops while
  /// the app is still backgrounded, managed playback must not continue as
  /// hidden audio indefinitely.
  @ObservationIgnored
  var isApplicationInBackground = false

  /// True only when SwiftVLC paused native playback for device/app lifecycle
  /// while deliberately preserving the user's active playback intent. This is
  /// the gate that lets foreground/reset recovery resume that exact pause
  /// without ever resuming a user-paused player.
  var isPlaybackSuspendedForManagedAudioLifecycle: Bool {
    get { player.isManagedAudioLifecycleSuspended }
    set { player.isManagedAudioLifecycleSuspended = newValue }
  }

  /// Independent from app/device lifecycle suspension: media services can be
  /// lost while the app is also backgrounded. Each recovery signal clears only
  /// its own cause, and playback resumes after the final cause is gone.
  var isPlaybackSuspendedForMediaServices: Bool {
    get { player.isManagedAudioMediaServicesSuspended }
    set { player.isManagedAudioMediaServicesSuspended = newValue }
  }

  var isManagedAudioResumeDeniedByInterruption: Bool {
    get { player.isManagedAudioResumeDeniedByInterruption }
    set { player.isManagedAudioResumeDeniedByInterruption = newValue }
  }

  var isManagedAudioResumePendingActivation: Bool {
    get { player.isManagedAudioResumePendingActivation }
    set { player.isManagedAudioResumePendingActivation = newValue }
  }

  /// Broadcasts ``PiPEvent``s to every ``pipEvents`` subscriber.
  /// Terminated in deinit so subscribers' streams finish with the
  /// controller.
  @ObservationIgnored
  let pipEventBroadcaster = Broadcaster<PiPEvent>()
  @ObservationIgnored
  let pipEventEnvelopeBroadcaster = Broadcaster<PiPEventEnvelope>()
  #if os(iOS)
  @ObservationIgnored
  let pipContinuityEventBroadcaster = Broadcaster<PiPContinuityEvent>()
  #endif
  @ObservationIgnored
  let pipSnapshotBroadcaster = Broadcaster<PiPSnapshot>()
  /// Lossless qualification-only record of every control-timebase write.
  /// Clock snapshots can be sampled; corrections cannot, because several can
  /// occur between two polls during a transition.
  @ObservationIgnored
  nonisolated let timebaseCorrectionBroadcaster = Broadcaster<PiPTimebaseCorrection>()
  @ObservationIgnored
  var timebaseCorrectionSequence: UInt64 = 0
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

  /// The best-known reason for an in-flight PiP stop, recorded by the
  /// first discriminating signal (restore callback, start failure,
  /// programmatic ``stop()``) and consumed by the stop delegate
  /// callbacks. `nil` when no discriminating signal has been observed;
  /// see ``PiPController/pipEvents`` for the resolution rules.
  @ObservationIgnored
  var pendingStopReason: PiPStopCause?

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
  var deferredPause: DeferredPauseState = .idle

  /// How a deferred PiP pause finished.
  ///
  /// Not surfaced on ``PiPEvent`` because that is a public non-frozen enum and
  /// adding a case would be source-breaking for exhaustive switches. Observe
  /// ``deferredPauseOutcome`` separately for this command result; playback
  /// intent is also reconciled onto ``Player/isPlaybackRequestedActive``.
  public enum DeferredPauseOutcome: Sendable, Equatable {
    /// libVLC accepted the pause.
    case issued
    /// Superseded, or the session left a pausable state before it could be
    /// issued.
    case cancelled
    /// The input never became pausable within the retry bound. Playback keeps
    /// running and the published intent is reconciled back to active.
    case rejected
  }

  /// The outcome of the most recent deferred pause.
  ///
  /// This property is `nil` before the first attempt and while a new attempt
  /// is in flight. Observe it to learn whether libVLC accepted the pause,
  /// whether another command cancelled it, or whether SwiftVLC restored
  /// active playback intent after exhausting the bounded retry window.
  public private(set) var deferredPauseOutcome: DeferredPauseOutcome?

  /// Exact ownership of a deferred-pause outcome publication. Observation
  /// invokes app callbacks before the synthesized setter body, so an observer
  /// can synchronously start or cancel a newer attempt while an older result is
  /// still suspended at that boundary.
  @ObservationIgnored
  var deferredPauseOutcomePublicationRevision: UInt64 = 0

  /// Publishes an outcome and returns the exact revision when this call still
  /// owns the publication after Observation callbacks have run. A callback
  /// may synchronously start a newer command before `withMutation` returns;
  /// callers with follow-on side effects must validate this token.
  @discardableResult
  func setDeferredPauseOutcome(
    _ outcome: DeferredPauseOutcome?
  ) -> UInt64? {
    precondition(
      deferredPauseOutcomePublicationRevision < UInt64.max,
      "PiP deferred-pause outcome publication revision exhausted"
    )
    deferredPauseOutcomePublicationRevision += 1
    let revision = deferredPauseOutcomePublicationRevision
    guard deferredPauseOutcome != outcome else { return revision }
    withMutation(keyPath: \.deferredPauseOutcome) {
      guard deferredPauseOutcomePublicationRevision == revision else { return }
      _deferredPauseOutcome = outcome
    }
    guard
      deferredPauseOutcomePublicationRevision == revision,
      deferredPauseOutcome == outcome
    else { return nil }
    return revision
  }

  func ownsDeferredPauseOutcomePublication(_ revision: UInt64) -> Bool {
    deferredPauseOutcomePublicationRevision == revision
  }

  enum DeferredPauseState {
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
  /// Number of AVKit skips still waiting for a terminal native seek outcome.
  /// Overlapping requests are counted so completion of a superseded request
  /// cannot re-enable timebase retracking while its successor is still pending.
  @ObservationIgnored
  var pendingSkipCount = 0

  /// Whether PiP can be started right now.
  ///
  /// Returns `false` on devices or simulators that don't support PiP,
  /// and briefly after initialization until the system has validated
  /// the layer. Observe this before enabling a "Picture-in-Picture"
  /// button in your UI.
  public private(set) var isPossible: Bool = false

  /// Exact ownership for ``isPossible`` publication across Observation's
  /// synchronous callback boundary.
  @ObservationIgnored
  var possiblePublicationRevision: UInt64 = 0

  /// Whether a PiP window is currently visible.
  public private(set) var isActive: Bool = false

  /// Exact ownership for ``isActive`` publication across Observation's
  /// synchronous callback boundary.
  @ObservationIgnored
  var activePublicationRevision: UInt64 = 0

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
  /// Hooks up vmem rendering callbacks and follows the player's inherited
  /// ``Player/appleAudioSessionPolicy`` for audio-session ownership.
  /// - Parameter player: The player to control.
  public init(player: Player) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
    startsAutomaticallyFromInline = true
    managesAudioSession = player.appleAudioSessionPolicy.managesAudioSession
    audioSessionPolicyDiagnostic = nil
    audioSessionActivation = nil
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

    startAudioSessionObserversIfManaged()
    setupControlTimebase()
    attachCallbacks()
    setupPiPController()
    startStateObserver()
    startPlaybackIntentObserver()
    player.registerNativeHandleSnapshotObserver(self)
  }

  #if os(iOS)
  init(
    player: Player,
    nativeBackend: IOSNativePiPBackend,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true,
    audioSessionPolicyDiagnostic: AppleAudioSessionPolicyDiagnostic? = nil,
    audioSessionActivation: (@MainActor () throws -> Void)? = nil
  ) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
    self.audioSessionPolicyDiagnostic = audioSessionPolicyDiagnostic
    self.audioSessionActivation = audioSessionActivation
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
    managesAudioSession: Bool = true,
    audioSessionPolicyDiagnostic: AppleAudioSessionPolicyDiagnostic? = nil
  ) {
    self.player = player
    playbackDriver = .live(player: player)
    pauseDebounce = .milliseconds(250)
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
    self.audioSessionPolicyDiagnostic = audioSessionPolicyDiagnostic
    audioSessionActivation = nil
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
    audioSessionPolicyDiagnostic = nil
    audioSessionActivation = nil
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

    startAudioSessionObserversIfManaged()
    setupControlTimebase()
    attachCallbacks()
    setupPiPController()
    startStateObserver()
    startPlaybackIntentObserver()
    player.registerNativeHandleSnapshotObserver(self)
  }

  isolated deinit {
    invalidateForLifecycleEnd()
  }

  /// Releases every controller-owned observation and callback claim.
  ///
  /// This stays internal so deterministic lifecycle tests can exercise the
  /// same cleanup as `deinit` without using ARC timing as a synchronization
  /// primitive. Normal clients release the controller instead.
  func invalidateForLifecycleEnd() {
    guard !didInvalidateForLifecycleEnd else { return }
    didInvalidateForLifecycleEnd = true

    pipEventBroadcaster.terminate()
    pipEventEnvelopeBroadcaster.terminate()
    #if os(iOS)
    pipContinuityEventBroadcaster.terminate()
    #endif
    pipSnapshotBroadcaster.terminate()
    timebaseCorrectionBroadcaster.terminate()
    cancelDeferredPause()
    stateObserverTask?.cancel()
    timingObserverTask?.cancel()
    effectivePlaybackRateObserverTask?.cancel()
    playbackIntentObserverTask?.cancel()
    audioSessionBackgroundPauseTask?.cancel()
    possibleObservation = nil
    activeObservation = nil
    deactivateAudioSessionIfNeeded()
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
    let bridge = player.eventBridge
    let registration = DirectPiPVideoCallbackRegistration(
      renderer: renderer,
      playbackGeneration: { bridge.currentPlaybackGeneration }
    )
    callbackRegistration = registration
    guard player.claimDirectPiPVideoCallbacks(registration) else {
      invalidateCallbackSnapshot()
      return
    }
    // Publish the handle the AVKit callback threads will interrogate. Until
    // this runs the snapshot reports "not attached" and the synchronous
    // queries answer with their stable defaults.
    refreshCallbackSnapshot()
  }

  private func setupPiPController() {
    guard callbackRegistration?.isBound == true else { return }
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

  func updatePiPPossible(_ isPossible: Bool) {
    precondition(
      possiblePublicationRevision < UInt64.max,
      "PiP possible publication revision exhausted"
    )
    possiblePublicationRevision += 1
    let revision = possiblePublicationRevision
    let hasRenderableBackend = callbackRegistration?.isBound ?? (nativeBackend != nil)
    let effectiveValue = isPossible && hasRenderableBackend
    guard self.isPossible != effectiveValue else { return }
    var didCommit = false
    withMutation(keyPath: \.isPossible) {
      guard possiblePublicationRevision == revision else { return }
      _isPossible = effectiveValue
      didCommit = true
    }
    guard didCommit, possiblePublicationRevision == revision else { return }
    publishPiPSnapshot()
  }

  func updatePiPActive(_ isActive: Bool) {
    precondition(
      activePublicationRevision < UInt64.max,
      "PiP active publication revision exhausted"
    )
    activePublicationRevision += 1
    let revision = activePublicationRevision
    guard self.isActive != isActive else { return }
    // AVKit may retain sample-buffer backing storage across PiP transitions.
    // Isolate that ownership before publishing the active boundary so the
    // bounded libVLC vmem pool always has a buffer with which to make forward
    // progress. Inline playback remains zero-copy.
    var didCommit = false
    withMutation(keyPath: \.isActive) {
      guard activePublicationRevision == revision else { return }
      renderer.setPresentationCopyRequired(isActive)
      callbackRegistration?.setPresentationCopyRequired(isActive)
      _isActive = isActive
      didCommit = true
    }
    guard didCommit, activePublicationRevision == revision else { return }
    handlePiPActiveChangedForManagedAudioSession(isActive)
    guard activePublicationRevision == revision else { return }
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

  // MARK: - State Observation

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

  func handlePlaybackIntentChanged(_ active: Bool) {
    // AsyncStream delivery can trail a media-services reset. Revalidate an
    // active sample against the Player-owned intent before it can reactivate
    // audio focus or cancel the reset's pause barrier.
    guard !active || player.isPlaybackRequestedActive else { return }
    if active {
      // Lifecycle and media-services suspension preserve active playback
      // intent on purpose. A queued copy of that intent is therefore not a
      // recovery signal and must not retake audio focus after the suspension
      // path released it. Foregrounding, PiP activation, or media-services
      // reset owns the corresponding reactivation and resume. The one
      // exception is an activation that those recovery paths already approved
      // but could not complete transiently; a later signal must retry it.
      if
        isManagedAudioResumePendingActivation
        || (!isPlaybackSuspendedForManagedAudioLifecycle
          && !isPlaybackSuspendedForMediaServices) {
        activateAudioSessionIfNeeded()
      }
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
    let requiresFreshPlaybackIntent = playing
      && player.requiresFreshPlaybackIntentAfterMediaServicesReset

    // Set immediately so isPlaybackPaused returns the correct value
    // when PiP queries it right after this call (before VLC catches up).
    pipPlaybackActive = playing
    pendingPiPPlaybackState = playing

    if playing {
      playbackDriver.cancelPendingPause(nil, nil, .resume)
      if let started = playbackDriver.startStoppedPlayback?() {
        // Play in the PiP window after the media ended, or before it ever
        // started. There is nothing to resume, and publishing intent alone
        // left the window showing "playing" over stopped media. A PiP-issued
        // pause belonged to the session that is over.
        clearIssuedPauseFlag()
        if !started {
          pendingPiPPlaybackState = nil
          pipPlaybackActive = player.isPlaybackRequestedActive
        }
        syncTimebase(playing: player.isActive)
        invalidatePictureInPicturePlaybackState()
        return
      }
      let resumeRequest = requestResumeIfNeeded(force: requiresFreshPlaybackIntent)
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

  #if os(iOS)
  func handleNativePictureInPictureWillStart(
    mediaGeneration: PlaybackGeneration?
  ) {
    clearUnownedStopReasonBeforeStart()
    activateAudioSessionIfNeeded()
    syncPlaybackStateForPictureInPicture()
    invalidatePictureInPicturePlaybackState()
    publishPiPEvent(.willStart, mediaGeneration: mediaGeneration)
  }

  func handleNativePictureInPictureDidStart(
    mediaGeneration: PlaybackGeneration?
  ) {
    clearUnownedStopReasonBeforeStart()
    syncPlaybackStateForPictureInPicture()
    invalidatePictureInPicturePlaybackState()
    updatePiPActive(true)
    publishPiPEvent(.didStart, mediaGeneration: mediaGeneration)
  }

  func handleNativePictureInPictureWillStop(
    mediaGeneration: PlaybackGeneration?
  ) {
    let cause = resolveWillStopReason(mediaGeneration: mediaGeneration)
    publishPiPEvent(
      .willStop(reason: cause.compatibilityReason),
      stopCause: cause,
      mediaGeneration: mediaGeneration
    )
  }

  func handleNativePictureInPictureDidStop(
    mediaGeneration: PlaybackGeneration?
  ) {
    let cause = resolveStopReason(mediaGeneration: mediaGeneration)
    updatePiPActive(false)
    publishPiPEvent(
      .didStop(reason: cause.compatibilityReason),
      stopCause: cause,
      mediaGeneration: mediaGeneration
    )
  }

  func handleNativePictureInPictureFailedToStart(
    _ error: any Error,
    mediaGeneration: PlaybackGeneration?
  ) {
    updatePiPActive(false)
    publishPiPEvent(.failedToStart(error), mediaGeneration: mediaGeneration)
  }

  func handleNativePictureInPictureControllerReplacement(
    wasActive: Bool,
    mediaGeneration: PlaybackGeneration?
  ) {
    if wasActive {
      notePendingStopReason(.controllerReplaced)
      handleNativePictureInPictureWillStop(mediaGeneration: mediaGeneration)
      handleNativePictureInPictureDidStop(mediaGeneration: mediaGeneration)
    }
    pipControllerGeneration &+= 1
    clearPiPLifecycleAttribution()
    publishPiPSnapshot()
  }
  #endif

  /// Mirrors the native backend's active flag. On supported libVLC revisions,
  /// lifecycle events come from the forwarding AVKit delegate bridge and this
  /// path updates state only. It still synthesizes `.didStart` / `.didStop`
  /// with ``PiPStopReason/unknown`` when no delegate was available to bridge.
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
      // This synthesized fallback cannot distinguish an unprompted native
      // close, so its version-1 event must remain `.unknown`. Preserve any
      // detail SwiftVLC did observe (for example an explicit `stop()`) only in
      // the extensible envelope.
      let resolvedCause = resolveStopReason(mediaGeneration: mediaGeneration)
      let cause: PiPStopCause = resolvedCause == .userClosed ? .unknown : resolvedCause
      publishPiPEvent(
        .didStop(reason: .unknown),
        stopCause: cause,
        mediaGeneration: mediaGeneration
      )
    }
  }

  func handleNativePictureInPictureSetPlaying(_ playing: Bool) {
    handleSetPlaying(playing)
  }
  #endif
}

#endif
