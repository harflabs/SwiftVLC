import CLibVLC
import Foundation
import Observation
import Synchronization

/// An observable media player.
///
/// `Player` wraps `libvlc_media_player_t` with `@Observable` and
/// `@MainActor`, so SwiftUI views update in response to libVLC state
/// without a publisher adapter.
///
/// The observable properties (`state`, `currentTime`, `duration`,
/// and the track lists) are fed by an internal event consumer. No
/// delegate protocols, Combine publishers, or manual bridging are
/// involved.
@Observable
@MainActor
public final class Player {
  // MARK: - Observable State

  /// The latest playback state delivered by libVLC's asynchronous event
  /// stream.
  ///
  /// This observable mirror can briefly lag the underlying player after a
  /// transport command. Read ``nativePlaybackState`` when transport logic
  /// requires a synchronous native-state snapshot instead of UI observation.
  public internal(set) var state: PlayerState = .idle

  /// Whether playback controls should currently present the media as
  /// active.
  ///
  /// libVLC state changes are asynchronous: a pause request can remain
  /// in flight while the native player still reports `.playing`, and a
  /// resume request can remain in flight while it still reports
  /// `.paused`. This property follows the user's latest playback intent
  /// synchronously so transport controls, including Picture in Picture,
  /// stay visually aligned while libVLC catches up.
  public internal(set) var isPlaybackRequestedActive: Bool = false

  /// Current playback time.
  public internal(set) var currentTime: Duration = .zero

  /// Total media duration (nil until known).
  public internal(set) var duration: Duration? {
    didSet { didUpdateDuration() }
  }

  /// Whether the current media is seekable.
  public internal(set) var isSeekable: Bool = false {
    didSet { publishCapabilitySnapshot() }
  }

  /// Whether the current media can be paused.
  public internal(set) var isPausable: Bool = false

  /// Buffer fill, normalized to `0.0...1.0`.
  ///
  /// Updated continuously while playback is active, including while
  /// ``state`` is `.paused` or `.playing`. Read this for a progress
  /// bar; the `state` enum only carries lifecycle information.
  public internal(set) var bufferFill: Float = 0

  /// Number of decoded video outputs; `0` when none.
  ///
  /// Mirrors libVLC's video-output count as reported by
  /// ``PlayerEvent/voutChanged(_:)``. Stays `0` for audio-only media
  /// and resets when media is loaded or replaced. See also
  /// ``hasVideoOutput`` for a live probe of whether a video track is
  /// selected and decoding.
  public internal(set) var activeVideoOutputs: Int = 0

  /// Current low-rate, generation-scoped playback-health snapshot.
  ///
  /// This is sampled at most four times per second. It is suitable for UI and
  /// diagnostics without turning a 4K60 decode path into 60 observable writes
  /// per second. Use ``playbackHealthEvents`` for semantic transitions.
  public internal(set) var playbackHealth = PlaybackHealthSnapshot(
    generation: PlaybackGeneration(0),
    state: .idle,
    revision: 0
  )

  /// The currently loaded media.
  public internal(set) var currentMedia: Media? {
    get {
      access(keyPath: \.currentMedia)
      return currentMediaStorage
    }
    set {
      withMutation(keyPath: \.currentMedia) {
        currentMediaStorage = newValue
      }
    }
  }

  /// Whether the last `stopped` transition was a natural end of media.
  ///
  /// Set when ``PlayerEvent/endReached-enum.case`` is synthesized; reset by the
  /// next ``load(_:)``, ``play(_:)``, or ``play()``. See
  /// ``PlayerEvent/endReached-enum.case`` for what counts as a natural end.
  public internal(set) var didReachEnd: Bool = false

  /// Available audio tracks.
  public internal(set) var audioTracks: [Track] = []

  /// Available video tracks.
  public internal(set) var videoTracks: [Track] = []

  /// Available subtitle tracks.
  public internal(set) var subtitleTracks: [Track] = []

  // MARK: - Internal

  @ObservationIgnored
  nonisolated(unsafe) var pointer: OpaquePointer // libvlc_media_player_t*
  @ObservationIgnored
  var nativeHandleLifetime: NativePlayerHandleLifetime
  #if os(iOS) || os(macOS)
  @ObservationIgnored
  weak var directPiPVideoCallbackRegistration: DirectPiPVideoCallbackRegistration?
  @ObservationIgnored
  var directPiPVideoCallbackSlot: DirectPiPVideoCallbackSlot?
  @ObservationIgnored
  var directPiPVideoCallbackGeneration: UInt64 = 0
  #endif
  let eventBridge: EventBridge
  let nativeSeekMonitor: NativeSeekMonitor
  nonisolated let endCoordinator = PlaybackEndCoordinator()
  nonisolated let playbackIntentBridge: Broadcaster<Bool>
  /// Carries normalized lifecycle transitions. See ``stateTransitions``.
  nonisolated let stateTransitionBridge = Broadcaster<PlayerState>(defaultBufferSize: 64)
  nonisolated let playbackStatusBridge = Broadcaster<PlaybackStatus>(defaultBufferSize: 64)
  nonisolated let playbackHealthSnapshotBridge = Broadcaster<PlaybackHealthSnapshot>(
    defaultBufferSize: 16
  )
  nonisolated let playbackHealthEventBridge = Broadcaster<PlaybackHealthEvent>(
    defaultBufferSize: 16
  )
  nonisolated let subtitleTextBridge = SubtitleTextBridge()
  /// ``isPlaybackRequestedActive`` mirrored for readers that cannot touch the
  /// main actor.
  ///
  /// AVKit and AppKit ask PiP whether playback is paused from their own
  /// threads and expect an answer immediately. Blocking those threads on the
  /// main actor is what lets a teardown already waiting on them deadlock, so
  /// the value they need is published here and read atomically instead.
  nonisolated let nonisolatedPlaybackIntent = Atomic<Bool>(false)
  /// Duration and seekability tagged with the media generation they describe,
  /// for consumers that must not mistake the previous media's capability for
  /// the current one. See ``PlayerCapabilitySnapshot``.
  nonisolated let capabilitySnapshot = Mutex(
    PlayerCapabilitySnapshot(playbackGeneration: PlaybackGeneration(0))
  )
  #if os(iOS) || os(macOS)
  /// Consumers caching the native handle for lock-free callback reads. See
  /// ``NativeHandleSnapshotObserver``.
  @ObservationIgnored
  var nativeHandleSnapshotObservers: [WeakNativeHandleSnapshotObserver] = []
  #endif

  /// Set while a multi-property capability change is in progress, so the
  /// per-property `didSet` publishes do not expose an intermediate mix of the
  /// outgoing and incoming media. See ``resetMediaDerivedState()``.
  @ObservationIgnored var isSuppressingCapabilityPublish = false
  /// Qualification-only fault injection that drops raw length and seekability
  /// events while leaving native polling active. This proves PiP capability
  /// convergence does not depend on callbacks libVLC may omit in production.
  @ObservationIgnored var isSuppressingRawCapabilityEvents = false
  @ObservationIgnored var suppressedRawLengthEventCount = 0
  @ObservationIgnored var suppressedRawSeekableEventCount = 0
  @ObservationIgnored var eventTask: Task<Void, Never>?
  @ObservationIgnored var playbackHealthSamplingTask: Task<Void, Never>?
  @ObservationIgnored var playbackHealthMonitoringState = PlaybackHealthMonitoringState()
  /// Exact ownership of one playback-health publication. Generation and
  /// native-handle identity reject media replacement, while this revision
  /// rejects a newer same-generation sample published from Observation's
  /// synchronous `onChange` callback.
  @ObservationIgnored var playbackHealthPublicationRevision: UInt64 = 0
  @ObservationIgnored var _position: Double = 0
  @ObservationIgnored var _equalizer: Equalizer?
  @ObservationIgnored var _volume: Float = 1.0
  @ObservationIgnored var _isMuted: Bool = false
  @ObservationIgnored var _aspectRatio: AspectRatio = .default
  enum PauseTransition {
    case pausing
    case resuming
  }

  enum DeferredPauseCommand {
    case pause
    case resume
  }

  /// Latest explicit transport intent. Unlike a generation-scoped deferred
  /// command, this survives a native playlist boundary so adoption can carry
  /// a pause or resume that raced with the media switch.
  @ObservationIgnored
  var playbackControlIntent: DeferredPauseCommand? {
    didSet { playbackControlIntentRevision &+= 1 }
  }

  /// Monotonic identity of the latest explicit transport command. PiP uses
  /// this to retire only the pause it owns without erasing a newer app command
  /// that happens to target the same media generation.
  @ObservationIgnored
  var playbackControlIntentRevision: UInt64 = 0
  /// Exact ownership of the two public playback-intent notifications. This is
  /// distinct from `playbackControlIntentRevision`: native reconciliation and
  /// media reset also publish intent, and either can synchronously re-enter a
  /// newer command through Observation.
  @ObservationIgnored var playbackIntentPublicationRevision: UInt64 = 0
  @ObservationIgnored var intentRevisions = PlayerIntentRevisions()
  /// Storage for ``currentMedia`` is explicit so a load transaction can
  /// revalidate its playback generation *inside* Observation's synchronous
  /// mutation body. A nested `load()` from `onChange` must win instead of
  /// returning to an older synthesized setter that then overwrites it.
  @ObservationIgnored var currentMediaStorage: Media?
  /// Non-nil while `load(_:)` is publishing one exact generation's media and
  /// reset state. Observation callbacks run before mutation bodies, so every
  /// native control—including `play()`—fails closed until that transaction
  /// either commits or is superseded by a nested load.
  @ObservationIgnored var mediaPublicationGeneration: UInt64?

  /// `@Observable`'s synthesized setters open their own `withMutation` scope.
  /// Generation-scoped transactions already own that scope so they must write
  /// the macro backing storage directly; otherwise a synchronously rearmed
  /// observer can run between the generation check and the nested setter body.
  func storeStateWithoutNestedObservation(_ value: PlayerState) {
    _state = value
  }

  func storePlaybackIntentWithoutNestedObservation(_ value: Bool) {
    _isPlaybackRequestedActive = value
  }

  func storeCurrentTimeWithoutNestedObservation(_ value: Duration) {
    _currentTime = value
  }

  func storePositionWithoutNestedObservation(_ value: Double) {
    _position = value
  }

  func storeDurationWithoutNestedObservation(_ value: Duration?) {
    _duration = value
    didUpdateDuration()
  }

  func storeSeekableWithoutNestedObservation(_ value: Bool) {
    _isSeekable = value
    publishCapabilitySnapshot()
  }

  func storePausableWithoutNestedObservation(_ value: Bool) {
    _isPausable = value
  }

  func storeBufferFillWithoutNestedObservation(_ value: Float) {
    _bufferFill = value
  }

  func storeActiveVideoOutputsWithoutNestedObservation(_ value: Int) {
    _activeVideoOutputs = value
  }

  func storePlaybackHealthWithoutNestedObservation(_ value: PlaybackHealthSnapshot) {
    _playbackHealth = value
  }

  func storeDidReachEndWithoutNestedObservation(_ value: Bool) {
    _didReachEnd = value
  }

  func removeAllAudioTrackStorageWithoutNestedObservation() {
    _audioTracks.removeAll(keepingCapacity: false)
  }

  func removeAllVideoTrackStorageWithoutNestedObservation() {
    _videoTracks.removeAll(keepingCapacity: false)
  }

  func removeAllSubtitleTrackStorageWithoutNestedObservation() {
    _subtitleTracks.removeAll(keepingCapacity: false)
  }

  func storeAudioTracksWithoutNestedObservation(_ value: [Track]) {
    _audioTracks = value
  }

  func storeVideoTracksWithoutNestedObservation(_ value: [Track]) {
    _videoTracks = value
  }

  func storeSubtitleTracksWithoutNestedObservation(_ value: [Track]) {
    _subtitleTracks = value
  }

  /// Receipt for the most recent pause that reached libVLC.
  ///
  /// A deferred pause can be issued by the event consumer while the PiP
  /// controller is sleeping between retries. The intent revision alone says
  /// which command is current, not whether that command actually crossed the
  /// native boundary, so the controller needs this exact generation/revision
  /// pair to distinguish an issued pause from a still-pending one.
  @ObservationIgnored
  var lastIssuedPausePlaybackGeneration: UInt64?
  @ObservationIgnored
  var lastIssuedPausePlaybackControlRevision: UInt64?

  #if os(iOS) || os(macOS)
  /// Candidate-bound fault state for the physical deferred-pause lane.
  /// Mutation is reachable only through qualification SPI; keeping the state
  /// in the live Player path ensures Release builds exercise the same pause
  /// generation and cleanup machinery as production.
  @ObservationIgnored
  var qualificationPauseFault = QualificationPauseFaultState()
  #endif

  #if DEBUG
  enum MediaSpecificNativeDispatch: Equatable {
    case readNativePlaybackState
    case readVideoSize
    case readABLoop
    case readChapterCount
    case readCurrentChapter
    case readTitleCount
    case readCurrentTitle
    case readTitles
    case readChapters
    case readTracks(TrackType)
    case readPrograms
    case readSelectedProgram
    case readProgramScrambled
    case takeSnapshot
    case startRecording
    case stopRecording
    case setABLoopTime
    case setABLoopPosition
    case resetABLoop
    case navigate
    case setChapter
    case nextChapter
    case previousChapter
    case setTitle
    case selectProgram
    case addExternalTrack
    case selectTrack
    case unselectTrack
  }

  /// Lets deterministic tests advance the callback-lane generation at the
  /// otherwise unschedulable boundaries between a native probe and its
  /// generation revalidation. Compiled out of release builds.
  enum PauseProbeStage {
    case state
    case capability
    case nativePause
    case pauseRollback
    case resumeState
    case resumeRollback
  }

  @ObservationIgnored var _pauseProbeHookForTesting: ((PauseProbeStage) -> Void)?
  @ObservationIgnored var _nativePlaybackStateOverrideForTesting: PlayerState?
  @ObservationIgnored var _nativeLengthOverrideForTesting: Int64?
  @ObservationIgnored var _nativeSeekableOverrideForTesting: Bool?
  @ObservationIgnored var _nativeVolumeOverrideForTesting: Int32?
  @ObservationIgnored var _nativeMuteOverrideForTesting: Int32?
  @ObservationIgnored var _nativeCanPauseOverrideForTesting: Bool?
  @ObservationIgnored var _nativePauseSafetyOverrideForTesting: Bool?
  @ObservationIgnored var _nativeSetRendererOverrideForTesting: ((RendererItem?) -> Int32)?
  @ObservationIgnored var _nativeSetRendererTargetHookForTesting:
    ((OpaquePointer, RendererItem?) -> Void)?
  @ObservationIgnored var _nativePlayOverrideForTesting: (() -> Int32)?
  @ObservationIgnored var _nativeStopOverrideForTesting: (() -> Void)?
  @ObservationIgnored var _recastWaitTimeoutForTesting: Duration?
  /// Runs after replacement publication and before old-handle retirement,
  /// exposing that otherwise unschedulable ordering to deterministic tests.
  @ObservationIgnored var _nativePlayerReplacementWillReleaseOldHandleForTesting: (() -> Void)?
  @ObservationIgnored var _nativePlayerReplacementWillActivateForTesting: (() -> Void)?
  @ObservationIgnored var _nativeResumeCommandOverrideForTesting: (() -> Void)?
  @ObservationIgnored var _nativeResumeAuthorizationOverrideForTesting: ((Bool) -> Void)?
  @ObservationIgnored var _mediaSpecificNativeDispatchHookForTesting:
    ((MediaSpecificNativeDispatch) -> Void)?
  @ObservationIgnored var _observableControlNativeDispatchHookForTesting:
    ((OpaquePointer, ObservableControlNativeDispatch) -> Void)?
  @ObservationIgnored var _seekOverridesForTesting = PlayerSeekTestOverrides()
  #endif

  @ObservationIgnored var pauseTransition: PauseTransition? {
    didSet {
      pauseTransitionPlaybackGeneration = pauseTransition == nil
        ? nil
        : eventBridge.currentPlaybackGeneration
    }
  }

  /// Native playback generation the in-flight transition was issued against.
  @ObservationIgnored var pauseTransitionPlaybackGeneration: UInt64?
  @ObservationIgnored var deferredPauseCommand: DeferredPauseCommand? {
    didSet {
      deferredPauseCommandPlaybackGeneration = deferredPauseCommand == nil
        ? nil
        : eventBridge.currentPlaybackGeneration
    }
  }

  /// Native playback generation the deferred command was accepted against.
  /// The event bridge can advance before its media-change event reaches the
  /// main actor, so this is more authoritative than `sessionGeneration` while
  /// a MediaListPlayer is opening its next item.
  @ObservationIgnored var deferredPauseCommandPlaybackGeneration: UInt64?

  /// Managed audio lifecycle can pause the native player without changing the
  /// user's active playback intent. This ownership lives on `Player`, not on a
  /// transient PiP controller, so a same-player SwiftUI reconstruction can
  /// still recover the exact library-issued pause.
  @ObservationIgnored var preservesPlaybackIntentForManagedAudioSuspension = false
  @ObservationIgnored var isManagedAudioLifecycleSuspended = false
  @ObservationIgnored var isManagedAudioMediaServicesSuspended = false
  @ObservationIgnored var isManagedAudioResumeDeniedByInterruption = false
  @ObservationIgnored var isManagedAudioResumePendingActivation = false

  #if os(iOS)
  /// The one process-broker lease currently held for this player.
  ///
  /// A lease is bound to one exact native media-player handle. Keep the
  /// owning pointer beside the opaque token so handle replacement can release
  /// the predecessor through the correct owner before acquiring on the
  /// successor. Token zero is reserved by the native ABI and always means
  /// that SwiftVLC owns no managed-session claim.
  @ObservationIgnored var managedAppleAudioSessionLease: UInt64 = 0
  @ObservationIgnored var managedAppleAudioSessionLeaseOwner: OpaquePointer?
  #endif

  /// A media-services reset invalidates the process's audio objects and also
  /// revokes the playback permission that existed before the reset. Keep that
  /// boundary on the player rather than a transient PiP controller: queued
  /// native `.playing` events and controller reconstruction must not turn an
  /// old intent into a post-reset user action.
  @ObservationIgnored var requiresFreshPlaybackIntentAfterMediaServicesReset = false

  #if os(iOS)
  /// One notification subscription per player, independent of whether a PiP
  /// controller happens to exist. The player routes disruptions to one live
  /// managed controller when possible and otherwise applies the transport-
  /// safety fallback itself.
  @ObservationIgnored
  var managedAppleAudioSessionObservers: [any NSObjectProtocol] = []
  #endif

  #if os(iOS) || os(macOS)
  @ObservationIgnored
  let managedAppleAudioSessionControllers = NSHashTable<PiPController>.weakObjects()
  @ObservationIgnored
  weak var preferredManagedAppleAudioSessionController: PiPController?
  #endif

  /// Shadow of the string last passed to `Marquee.setText`. libVLC's text
  /// renderer keys its glyph-bitmap cache on the text string, so a style-
  /// only write (color/opacity/fontSize) hits the cached entry and draws
  /// with the previous style. The `Marquee` setters briefly write a different
  /// text to bust the cache, then restore this value.
  @ObservationIgnored var _marqueeText: String = ""
  /// In-flight task that restores `_marqueeText` after a cache-bust write.
  /// Held on `Player` (not `Marquee`) because `Marquee` is `~Escapable`
  /// and cannot store cross-call state. A new style write cancels and
  /// replaces this task so rapid mutations collapse into a single restore
  /// scheduled from the latest write.
  @ObservationIgnored var _marqueeRestoreTask: Task<Void, Never>?
  /// Shadows of per-player state that libVLC exposes no getter for (or
  /// whose live value can't be trusted mid-mutation). The native-handle
  /// replacement re-applies them to the fresh handle; without a shadow
  /// each silently reverts to its default on the first stop of
  /// drawable-hosted playback.
  @ObservationIgnored var _logoFile: String?
  @ObservationIgnored var _teletextPage: Int32?
  @ObservationIgnored var _deinterlaceState: Int32?
  @ObservationIgnored var _deinterlaceMode: String?
  @ObservationIgnored var _audioOutputModule: String?
  @ObservationIgnored var _audioOutputDevice: String?
  @ObservationIgnored var _viewpoint: Viewpoint?
  /// The list player currently driving this handle, if any. The native
  /// list player binds the raw `libvlc_media_player_t*` once, so every
  /// handle replacement must re-bind it or the list player keeps
  /// driving a released pointer.
  @ObservationIgnored weak var attachedMediaListPlayer: MediaListPlayer?
  /// Main-actor ABA guard for list ownership. Weak identity can become nil
  /// after attach/detach and look unchanged to a suspended recast; this epoch
  /// advances on every ownership transition even when the final value is nil.
  @ObservationIgnored var mediaListOwnershipEpoch: UInt64 = 0
  /// The platform view currently receiving video frames. Held strongly
  /// because libVLC stores the view as an unretained raw pointer in its
  /// `drawable-nsobject` variable and reads it asynchronously from the
  /// decode/vout thread. A view owned only by UIKit/AppKit can be
  /// released before libVLC notices, producing a dangling read and a
  /// segmentation fault — see VLCKit's `_drawable` ivar for the
  /// historical precedent. Cleared to nil in `deinit` *after* the libVLC
  /// pointer has been reset, and its lifetime is explicitly extended
  /// across the offloaded release so `libvlc_media_player_release` can
  /// tear down the vout before ARC releases the view.
  @ObservationIgnored var drawable: AnyObject?
  @ObservationIgnored var drawableOwner: ObjectIdentifier?
  @ObservationIgnored var needsDrawableRebindForPlayback = false
  @ObservationIgnored var nativePlayerHasHostedDrawable = false
  @ObservationIgnored var nativePlayerNeedsReplacementBeforePlayback = false
  /// True when ``load(_:)`` already committed the playback generation whose
  /// media is waiting for a fresh drawable-hosted native handle. The next
  /// `play()` must not mistake the retiring handle's terminal state for a
  /// cold replay and advance that generation a second time.
  @ObservationIgnored var nativePlayerReplacementHasCommittedMediaGeneration = false
  /// Whether `pointer` and its synchronous media-specific API surface describe
  /// ``currentMedia``. A drawable-safe `load(_:)` can commit the successor in
  /// Swift while deliberately leaving the retiring media on the old handle
  /// until `play()` installs a fresh one. During that interval native state,
  /// timeline, tracks, chapters, programs, recording, and frame controls all
  /// still belong to the predecessor and must fail closed.
  var nativeHandleRepresentsCurrentMedia: Bool {
    mediaPublicationGeneration == nil
      && !(nativePlayerNeedsReplacementBeforePlayback
        && nativePlayerReplacementHasCommittedMediaGeneration)
  }

  @ObservationIgnored var retainedDrawablesUntilNativePlayerRelease: [AnyObject] = []
  @ObservationIgnored var selectedRenderer: RendererItem?
  @ObservationIgnored var nativePlaybackStartWasObserved = false
  /// Monotonic exact-handle start history. The local bit remains as a DEBUG-
  /// friendly seam, while EventBridge is authoritative for list-driven and
  /// callback-entry starts that can precede MainActor delivery.
  var nativePlayerHasStartedPlayback: Bool {
    get {
      nativePlaybackStartWasObserved
        || eventBridge.currentNativeHandleHasStartedPlayback
    }
    set {
      nativePlaybackStartWasObserved = newValue
      if newValue {
        eventBridge.recordAcceptedPlaybackStart(
          playbackGeneration: eventBridge.currentPlaybackGeneration
        )
      }
    }
  }

  var currentPlaybackGenerationHasStartedPlayback: Bool {
    eventBridge.currentPlaybackGenerationHasStartedPlayback
  }

  @ObservationIgnored var isTextSubtitleCaptureEnabled = false
  @ObservationIgnored var subtitleTextNativeOperations = SubtitleTextNativeOperations.live

  /// Set synchronously by the first ``shutdown()`` caller, before it
  /// suspends, so every command issued from that point on sees a player that
  /// is already retiring.
  @ObservationIgnored var isShutdown = false
  /// The single teardown every ``shutdown()`` caller joins. Retained after
  /// completion so late callers still await a finished task rather than
  /// returning while an earlier teardown is mid-flight.
  @ObservationIgnored var shutdownTask: Task<Void, Never>?
  /// The in-flight ``stopAndWait()`` for one exact transport episode.
  /// Concurrent callers join only while the native handle, playback
  /// generation, and control boundary still identify that same Stop. A later
  /// Play/Resume or media adoption must create a fresh stop instead of
  /// inheriting the predecessor's eventual `Stopped` callback.
  @ObservationIgnored var stopAndWaitOperation: PlayerStopAndWaitOperation?
  @ObservationIgnored var nextStopAndWaitOperationID: UInt64 = 0
  /// The timeline revision established by the most recent accepted seek or
  /// media load. Clock samples stamped older than this are stale and are
  /// dropped rather than allowed to overwrite the seek target.
  @ObservationIgnored var acceptedTimelineRevision: UInt64 = 0
  /// Highest callback-order barrier committed to the observable timeline.
  /// Unlike `timelineRevision`, this sequence is issued under one lock shared
  /// by raw events, watched seek landings, wrapper dispatch, and exact frames.
  @ObservationIgnored var acceptedNativeTimelineEmissionSequence: UInt64 = 0
  /// The only seek still allowed to publish a terminal result.
  @ObservationIgnored var pendingSeekSettlement: PendingSeekSettlement?
  /// The single command that has crossed into libVLC's request-ID-less v4
  /// watcher. Its native ownership outlives public timeout or supersession.
  @ObservationIgnored var activeNativeSeek: ActiveNativeSeek?
  /// Latest accepted command waiting behind the active or externally-issued
  /// native episode. Replacements never enter VLC; only this newest command is
  /// retained for later dispatch.
  @ObservationIgnored var queuedNativeSeek: NativeSeekCommand?
  /// Latest raw clock samples withheld while one dispatched wrapper episode
  /// owns the request-ID-less watcher. Its attributed landing discards them; a
  /// timeout with no successor releases the best remaining observable truth.
  @ObservationIgnored var quarantinedSeekTimeline: QuarantinedSeekTimeline?
  /// Highest external seek episode whose landed point was published. The
  /// monitor epoch is monotonic across attachment rotations, so delayed or
  /// duplicate MainActor deliveries can never regain timeline authority.
  @ObservationIgnored var latestAppliedExternalSeekEpoch: UInt64 = 0
  /// Highest external epoch observed by a wrapper seek that subsequently
  /// crossed into native code. A delayed external landing from that same
  /// epoch is older than the wrapper dispatch even after the wrapper settles.
  @ObservationIgnored var latestWrapperDispatchExternalSeekEpoch: UInt64 = 0
  /// Frame commands awaiting libVLC's ID-matched post-display terminal event.
  /// Kept as a FIFO so rapid taps serialize through the single native slot.
  @ObservationIgnored var pendingFrameSteps: [PendingFrameStep] = []
  /// Requests removed from the dispatch FIFO after native cancellation lost
  /// to output commitment. Their exact terminal can settle the caller but is
  /// never allowed to overwrite a successor timeline boundary.
  @ObservationIgnored var committedFrameStepsAwaitingTerminal:
    [UInt64: CommittedFrameStepAwaitingTerminal] = [:]
  @ObservationIgnored var nextFrameRequestToken: UInt64 = 0
  /// Bumped when ``recast(to:)`` is superseded so suspended work rejects stale restoration.
  /// Internal transaction identity is intentionally ignored by Observation;
  /// public consumers receive coherent generation-tagged values through
  /// ``playbackStatus``.
  @ObservationIgnored var sessionGeneration: UInt64 = 0 {
    didSet {
      if sessionGeneration != oldValue {
        supersedePendingSeekSettlement()
        resetNativeSeekMonitorForCausalBoundary()
        cancelPendingFrameSteps()
      }
      #if os(iOS) || os(macOS)
      refreshNativeHandleSnapshots()
      #endif
    }
  }

  /// The native media the generation was last advanced for.
  /// libVLC reports a media change back as `.mediaChanged` whether or not the
  /// wrapper initiated it, so the handler cannot tell the two apart by the
  /// event alone. Comparing identity does: a change this player asked for has
  /// already advanced the generation and records itself here, while one that
  /// arrives from elsewhere — a ``MediaListPlayer`` advancing the list through
  /// libVLC directly — does not match and advances it.
  @ObservationIgnored var sessionGenerationMedia: OpaquePointer?
  let instance: VLCInstance

  /// The Apple audio-session owner inherited from the ``VLCInstance`` that
  /// created this player.
  ///
  /// The value is read-only and remains identical for every player sharing
  /// the same instance, including PiP controllers created later.
  public var appleAudioSessionPolicy: AppleAudioSessionPolicy {
    instance.appleAudioSessionPolicy
  }

  // MARK: - Lifecycle

  /// Creates a new player.
  /// - Parameter instance: The VLC instance to use.
  public init(instance: VLCInstance = .shared) {
    let p = Self.makeNativePlayer(instance: instance)
    pointer = p
    let initialNativeHandleLifetime = NativePlayerHandleLifetime(pointer: p)
    nativeHandleLifetime = initialNativeHandleLifetime
    self.instance = instance
    let nativeSeekEmissionAuthority = NativeSeekEmissionAuthority()
    let eventBridge = EventBridge(
      eventManager: libvlc_media_player_event_manager(p)!,
      endCoordinator: endCoordinator,
      nativeSeekEmissionAuthority: nativeSeekEmissionAuthority
    )
    self.eventBridge = eventBridge
    nativeSeekMonitor = NativeSeekMonitor(
      player: p,
      nativeHandleGeneration: eventBridge.currentNativeHandleGeneration,
      playbackGeneration: 0,
      emissionAuthority: nativeSeekEmissionAuthority
    )
    playbackIntentBridge = Broadcaster<Bool>(defaultBufferSize: 16)
    configureNativeSeekMonitor()
    startManagedAppleAudioSessionObservationIfNeeded()
    startEventConsumer()
    // Seeded so `playbackStatus` opens with the current pair from the moment
    // the player exists: a subscriber attaching before any state change would
    // otherwise replay nothing and wait, on an idle player forever.
    publishPlaybackStatus()
    playbackHealthSnapshotBridge.broadcast(playbackHealth)
  }

  static func makeNativePlayer(instance: VLCInstance) -> OpaquePointer {
    guard let p = libvlc_media_player_new(instance.pointer) else {
      preconditionFailure("Failed to create libvlc media player. Is the libvlc.xcframework linked correctly?")
    }
    return p
  }

  isolated deinit {
    stopManagedAppleAudioSessionObservationIfNeeded()
    _ = releaseManagedAppleAudioSessionLeaseIfNeeded()
    supersedePendingSeekSettlement()
    cancelPendingFrameSteps()
    closeNativeFrameResultLaneForTeardown()
    eventBridge.finishCurrentPlaybackGeneration(
      cause: .cancellation,
      playbackGeneration: sessionGeneration
    )
    eventTask?.cancel()
    _marqueeRestoreTask?.cancel()
    // The player is going away for good, so future subscribers must receive
    // an already-finished stream rather than one that can never emit.
    playbackIntentBridge.terminate()
    stateTransitionBridge.terminate()
    playbackStatusBridge.terminate()
    playbackHealthSnapshotBridge.terminate()
    playbackHealthEventBridge.terminate()
    subtitleTextBridge.terminate()
    playbackHealthSamplingTask?.cancel()
    #if os(iOS) || os(macOS)
    retireDirectPiPVideoCallbacksForHandleEnd()
    // No successor to move to here, unlike replacement and shutdown: the
    // player itself is being destroyed, so the only cached handle that stays
    // valid past this point is none.
    invalidateNativeHandleSnapshots()
    #endif
    // Tell libVLC to forget the drawable *before* release so the
    // vout thread observes a nil pointer rather than dereferencing a
    // view that is about to be released when `self`'s storage is torn
    // down. The view itself is captured into the offloaded closure
    // below so it outlives the libVLC teardown.
    libvlc_media_player_set_nsobject(pointer, nil)

    // Move every VLC cleanup call off the main actor so deinit never
    // blocks the UI thread. `libvlc_event_detach` waits for an in-flight
    // C callback to finish, and `libvlc_media_player_release` can block
    // on internal threads; both can stall the main actor for seconds
    // under load.
    //
    // Safety: `bridge` keeps the EventBridge (and its ContinuationStore)
    // alive until cleanup completes. `drawable` keeps the platform view
    // alive across `libvlc_media_player_release`, which tears down the
    // vout; if the view were released first, any in-flight vout-thread
    // read of `drawable-nsobject` would be use-after-free. The C player
    // pointer is a plain value. invalidate() MUST run before release()
    // so the event manager is still valid when detaching callbacks.
    let bridge = eventBridge
    let seekMonitor = nativeSeekMonitor
    // `AnyObject?` is not `Sendable` under Swift 6, but the capture is
    // write-once-read-never — the closure only holds the view alive,
    // it never reads or mutates it. `nonisolated(unsafe)` is the
    // narrow, explicit opt-out that matches that contract and avoids a
    // Mutex wrapper or an `@unchecked Sendable` box for a value we
    // never actually touch across threads.
    nonisolated(unsafe) let drawables =
      drawable.map { retainedDrawablesUntilNativePlayerRelease + [$0] }
        ?? retainedDrawablesUntilNativePlayerRelease
    nonisolated(unsafe) let p = pointer
    let lifetime = nativeHandleLifetime
    let resumeBeforeRelease = shouldResumeNativePlayerBeforeStop
    DispatchQueue.global(qos: .utility).async {
      Self.teardownNativePlayer(
        p,
        lifetime: lifetime,
        bridge: bridge,
        seekMonitor: seekMonitor,
        retainedDrawables: drawables,
        resumeBeforeStop: resumeBeforeRelease
      )
    }
  }
}
