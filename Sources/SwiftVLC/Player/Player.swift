import CLibVLC
import Foundation
import Observation
import os

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

  /// Current playback state.
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
  public internal(set) var duration: Duration?

  /// Whether the current media is seekable.
  public internal(set) var isSeekable: Bool = false

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
  /// ``hasVideoOutput`` for a live read of the same condition.
  public internal(set) var activeVideoOutputs: Int = 0

  /// The currently loaded media.
  public internal(set) var currentMedia: Media?

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

  // MARK: - Observable Playback Values

  /// Fractional playback position reported by libVLC, in `0.0 ... 1.0`.
  ///
  /// Use ``seek(to:)-(PlaybackPosition)`` for checked position-based seeking. This
  /// property is read-only so callers cannot accidentally issue an
  /// unchecked seek request through a raw `Double` write.
  public var position: Double {
    access(keyPath: \.position)
    return _position
  }

  /// Current volume level, normalized. `0.0` is silent, `1.0` is 100%.
  ///
  /// Backed by a shadow `_volume` instead of a live libVLC read.
  /// Before the audio output is initialized `libvlc_audio_get_volume`
  /// returns a negative sentinel (`-100` on libVLC 4.0), which would
  /// surface in the UI as `-100%` even while the user is hearing audio
  /// at the default level. The shadow starts at `1.0` and is refreshed
  /// from the native player on each state transition, once libVLC's
  /// audio output can be trusted.
  /// Use ``setAudioVolume(_:)`` to change volume through the typed
  /// ``Volume`` range.
  public var volume: Float {
    access(keyPath: \.volume)
    return _volume
  }

  /// Sets audio output volume through the typed ``Volume`` range.
  ///
  /// Before playback starts, libVLC may reject the native update because
  /// there is no initialized audio output yet; SwiftVLC still records the
  /// requested volume and re-applies it when playback creates or replaces
  /// the native player.
  ///
  /// - Throws: ``VLCError/operationFailed(_:)`` if playback is active and
  ///   libVLC rejects the native volume update.
  public func setAudioVolume(_ newVolume: Volume) throws(VLCError) {
    let nativeVolume = Int32((newVolume.rawValue * 100).rounded())
    let previousVolume = _volume
    let rc = withMutation(keyPath: \.volume) {
      _volume = newVolume.rawValue
      return libvlc_audio_set_volume(pointer, nativeVolume)
    }
    if rc != 0, currentMedia != nil, state.isActive {
      withMutation(keyPath: \.volume) {
        _volume = previousVolume
      }
      throw .operationFailed("Set audio volume to \(newVolume.rawValue)")
    }
  }

  /// Whether audio is muted. Shadowed by `_isMuted` for the same
  /// reason as `volume`: `libvlc_audio_get_mute` returns `-1` when the
  /// mute status is undefined, which a naive `Int32 > 0` check would
  /// silently map to `false` and hide a real mute toggle.
  public var isMuted: Bool {
    get {
      access(keyPath: \.isMuted)
      return _isMuted
    }
    set {
      withMutation(keyPath: \.isMuted) {
        _isMuted = newValue
        libvlc_audio_set_mute(pointer, newValue ? 1 : 0)
      }
    }
  }

  /// Current playback rate. `1.0` is normal speed.
  ///
  /// Use ``setPlaybackRate(_:)`` to request a new rate through the typed
  /// ``PlaybackRate`` range and receive libVLC rejection as
  /// ``VLCError/operationFailed(_:)``.
  public var rate: Float {
    access(keyPath: \.rate)
    return libvlc_media_player_get_rate(pointer)
  }

  /// Sets the playback rate, throwing if libVLC rejects the value.
  ///
  /// Typical rejections:
  /// - Live streams (HLS, RTSP) that only support `1.0` playback.
  /// - No media loaded yet. libVLC ignores the call until playback
  ///   starts.
  /// - Format-specific decoder limitations.
  ///
  /// ``setPlaybackRate(_:)`` is the public mutator.
  ///
  /// - Parameter newRate: Target rate. `1.0` is normal speed.
  /// - Throws: ``VLCError/operationFailed(_:)`` if libVLC rejects the rate.
  func setRate(_ newRate: PlaybackRate) throws(VLCError) {
    let rc = withMutation(keyPath: \.rate) {
      libvlc_media_player_set_rate(pointer, newRate.rawValue)
    }
    if rc != 0 {
      throw .operationFailed("Set rate to \(newRate.rawValue)")
    }
  }

  /// The currently selected audio track, or `nil` if none is selected.
  ///
  /// Setting to `nil` deselects the active audio track. Output stays
  /// silent until another track is chosen.
  public var selectedAudioTrack: Track? {
    get {
      access(keyPath: \.selectedAudioTrack)
      return audioTracks.first(where: \.isSelected)
    }
    set {
      withMutation(keyPath: \.selectedAudioTrack) {
        selectTrack(newValue, type: .audio)
      }
    }
  }

  /// The currently selected subtitle track, or `nil` if subtitles are off.
  ///
  /// Setting to `nil` deselects the active subtitle track.
  public var selectedSubtitleTrack: Track? {
    get {
      access(keyPath: \.selectedSubtitleTrack)
      return subtitleTracks.first(where: \.isSelected)
    }
    set {
      withMutation(keyPath: \.selectedSubtitleTrack) {
        selectTrack(newValue, type: .subtitle)
      }
    }
  }

  /// Video aspect ratio override.
  public var aspectRatio: AspectRatio = .default {
    didSet { applyAspectRatio() }
  }

  /// Audio delay relative to video. Positive values delay audio (make it play later).
  ///
  /// Use ``setAudioDelay(_:)`` to mutate this value with checked duration
  /// conversion.
  public var audioDelay: Duration {
    access(keyPath: \.audioDelay)
    return .microseconds(libvlc_audio_get_delay(pointer))
  }

  /// Sets the audio delay relative to video.
  ///
  /// - Throws: ``VLCError/invalidInput(_:)`` if the duration cannot be
  ///   represented in libVLC's microsecond unit, or
  ///   ``VLCError/operationFailed(_:)`` if libVLC rejects the update.
  public func setAudioDelay(_ newDelay: Duration) throws(VLCError) {
    let microseconds = try newDelay.checkedMicroseconds(parameter: "audioDelay")
    let rc = withMutation(keyPath: \.audioDelay) {
      libvlc_audio_set_delay(pointer, microseconds)
    }
    if rc != 0 {
      throw .operationFailed("Set audio delay")
    }
  }

  /// Subtitle delay relative to video. Positive values delay subtitles (make them appear later).
  ///
  /// Use ``setSubtitleDelay(_:)`` to mutate this value with checked
  /// duration conversion.
  public var subtitleDelay: Duration {
    access(keyPath: \.subtitleDelay)
    return .microseconds(libvlc_video_get_spu_delay(pointer))
  }

  /// Sets the subtitle delay relative to video.
  ///
  /// - Throws: ``VLCError/invalidInput(_:)`` if the duration cannot be
  ///   represented in libVLC's microsecond unit, or
  ///   ``VLCError/operationFailed(_:)`` if libVLC rejects the update.
  public func setSubtitleDelay(_ newDelay: Duration) throws(VLCError) {
    let microseconds = try newDelay.checkedMicroseconds(parameter: "subtitleDelay")
    let rc = withMutation(keyPath: \.subtitleDelay) {
      libvlc_video_set_spu_delay(pointer, microseconds)
    }
    if rc != 0 {
      throw .operationFailed("Set subtitle delay")
    }
  }

  /// Subtitle text scale factor (1.0 = 100%, 0.5 = 50%, 2.0 = 200%).
  ///
  /// Use ``setSubtitleScale(_:)`` to mutate this value through the typed
  /// ``SubtitleScale`` range.
  public var subtitleTextScale: Float {
    access(keyPath: \.subtitleTextScale)
    return libvlc_video_get_spu_text_scale(pointer)
  }

  /// Sets subtitle text scale through the typed ``SubtitleScale`` range.
  public func setSubtitleScale(_ newScale: SubtitleScale) {
    withMutation(keyPath: \.subtitleTextScale) {
      libvlc_video_set_spu_text_scale(pointer, newScale.rawValue)
    }
  }

  /// The player's role, used to hint the system about audio behavior.
  public var role: PlayerRole {
    get {
      access(keyPath: \.role)
      return PlayerRole(from: libvlc_media_player_get_role(pointer))
    }
    set {
      _ = withMutation(keyPath: \.role) {
        libvlc_media_player_set_role(pointer, newValue.cValue)
      }
    }
  }

  // MARK: - Convenience

  /// Whether transport controls should currently present playback as
  /// playing.
  ///
  /// This follows the latest accepted play/resume/pause intent rather
  /// than waiting for libVLC's asynchronous ``state`` transitions. Use
  /// ``state`` when you need the strict native lifecycle state.
  public var isPlaying: Bool {
    access(keyPath: \.isPlaying)
    return isPlaybackRequestedActive
  }

  /// Whether playback is active (playing or buffering during playback).
  public var isActive: Bool {
    access(keyPath: \.isActive)
    return state.isActive
  }

  /// Convenience access to current media statistics.
  public var statistics: MediaStatistics? {
    currentMedia?.statistics()
  }

  // MARK: - Event Stream

  /// Raw event stream for custom processing, with the default buffering
  /// policy (`.newest(64)`) and no filter.
  /// Most consumers should use `@Observable` properties instead.
  /// See ``events(policy:filter:)`` for the delivery guarantees and their
  /// limits.
  public nonisolated var events: AsyncStream<PlayerEvent> {
    eventBridge.makeStream(policy: .newest(64), filter: nil)
  }

  /// Raw event stream with an explicit buffering policy and an optional
  /// per-subscription filter.
  ///
  /// The default `.newest(64)` policy bounds memory but is lossy: a
  /// consumer stalled past 64 undelivered events silently loses the
  /// oldest ones, which can include one-shot terminal transitions such as
  /// `.stateChanged(.stopped)` or ``PlayerEvent/endReached-enum.case``. Consumers
  /// that must not miss those should pass `.unbounded`, ideally with a
  /// `filter` that keeps the `timeChanged`/`positionChanged` firehose out
  /// of the buffer.
  ///
  /// `filter` runs on libVLC's event thread for every event, outside any
  /// SwiftVLC lock — keep it fast and never block in it. Don't touch
  /// main-actor state from it: beyond the usual isolation rules, native
  /// teardown (handle replacement, player deinit) joins the event thread
  /// while detaching callbacks, so a filter blocked on the main actor
  /// can deadlock teardown against the very thread it is stalling.
  ///
  /// A delivery limit that no policy removes: when the player replaces
  /// its native handle (stopping drawable-hosted playback does this
  /// lazily, and ``recast(to:)``-style renderer changes do it
  /// mid-session), the bridge reattaches to the replacement handle before
  /// the old one finishes stopping on a background queue. Terminal events
  /// of the *swapped-out* handle are never delivered to any stream; state
  /// derived from them is reset by the swap itself.
  public nonisolated func events(
    policy: EventBufferingPolicy = .newest(64),
    filter: (@Sendable (PlayerEvent) -> Bool)? = nil
  ) -> AsyncStream<PlayerEvent> {
    eventBridge.makeStream(policy: policy, filter: filter)
  }

  /// Lossless stream of lifecycle state transitions — no firehose.
  ///
  /// Equivalent to an `.unbounded` ``events(policy:filter:)``
  /// subscription that keeps only `.stateChanged` payloads, so a lagging
  /// consumer can never lose a one-shot terminal transition. Memory is
  /// bounded in practice by the low rate of state changes.
  public nonisolated var stateTransitions: AsyncStream<PlayerState> {
    let upstream = eventBridge.makeStream(
      policy: .unbounded,
      filter: { event in
        if case .stateChanged = event { return true }
        return false
      }
    )
    let (stream, continuation) = AsyncStream<PlayerState>.makeStream(
      bufferingPolicy: .unbounded
    )
    let pump = Task {
      for await event in upstream {
        if case .stateChanged(let state) = event {
          continuation.yield(state)
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in
      pump.cancel()
    }
    return stream
  }

  nonisolated var playbackIntentEvents: AsyncStream<Bool> {
    playbackIntentBridge.subscribe()
  }

  // MARK: - Internal

  @ObservationIgnored
  nonisolated(unsafe) var pointer: OpaquePointer // libvlc_media_player_t*
  let eventBridge: EventBridge
  nonisolated let endCoordinator = PlaybackEndCoordinator()
  nonisolated let playbackIntentBridge: Broadcaster<Bool>
  var eventTask: Task<Void, Never>?
  var _position: Double = 0
  var _equalizer: Equalizer?
  var _volume: Float = 1.0
  var _isMuted: Bool = false
  enum PauseTransition {
    case pausing
    case resuming
  }

  enum DeferredPauseCommand {
    case pause
    case resume
  }

  var pauseTransition: PauseTransition?
  var deferredPauseCommand: DeferredPauseCommand?
  /// Shadow of the string last passed to `Marquee.setText`. libVLC's text
  /// renderer keys its glyph-bitmap cache on the text string, so a style-
  /// only write (color/opacity/fontSize) hits the cached entry and draws
  /// with the previous style. The `Marquee` setters briefly write a different
  /// text to bust the cache, then restore this value.
  var _marqueeText: String = ""
  /// In-flight task that restores `_marqueeText` after a cache-bust write.
  /// Held on `Player` (not `Marquee`) because `Marquee` is `~Escapable`
  /// and cannot store cross-call state. A new style write cancels and
  /// replaces this task so rapid mutations collapse into a single restore
  /// scheduled from the latest write.
  var _marqueeRestoreTask: Task<Void, Never>?
  /// Shadows of per-player state that libVLC exposes no getter for (or
  /// whose live value can't be trusted mid-mutation). The native-handle
  /// replacement re-applies them to the fresh handle; without a shadow
  /// each silently reverts to its default on the first stop of
  /// drawable-hosted playback.
  var _logoFile: String?
  var _teletextPage: Int32?
  var _deinterlaceState: Int32?
  var _deinterlaceMode: String?
  var _audioOutputModule: String?
  var _audioOutputDevice: String?
  var _viewpoint: Viewpoint?
  /// The list player currently driving this handle, if any. The native
  /// list player binds the raw `libvlc_media_player_t*` once, so every
  /// handle replacement must re-bind it or the list player keeps
  /// driving a released pointer.
  weak var attachedMediaListPlayer: MediaListPlayer?
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
  var drawable: AnyObject?
  var drawableOwner: ObjectIdentifier?
  var needsDrawableRebindForPlayback = false
  var nativePlayerHasHostedDrawable = false
  var nativePlayerNeedsReplacementBeforePlayback = false
  var retainedDrawablesUntilNativePlayerRelease: [AnyObject] = []
  var selectedRenderer: RendererItem?
  var nativePlayerHasStartedPlayback = false
  var isShutdown = false
  let instance: VLCInstance

  // MARK: - Lifecycle

  /// Creates a new player.
  /// - Parameter instance: The VLC instance to use.
  public init(instance: VLCInstance = .shared) {
    let p = Self.makeNativePlayer(instance: instance)
    pointer = p
    self.instance = instance
    eventBridge = EventBridge(
      eventManager: libvlc_media_player_event_manager(p)!,
      endCoordinator: endCoordinator
    )
    playbackIntentBridge = Broadcaster<Bool>(defaultBufferSize: 16)
    startEventConsumer()
  }

  static func makeNativePlayer(instance: VLCInstance) -> OpaquePointer {
    guard let p = libvlc_media_player_new(instance.pointer) else {
      preconditionFailure("Failed to create libvlc media player. Is the libvlc.xcframework linked correctly?")
    }
    return p
  }

  isolated deinit {
    eventTask?.cancel()
    _marqueeRestoreTask?.cancel()
    playbackIntentBridge.finishAll()
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
    let resumeBeforeRelease = pauseTransition == .pausing || nativePlaybackState == .paused
    DispatchQueue.global(qos: .utility).async {
      Self.teardownNativePlayer(
        p,
        bridge: bridge,
        retainedDrawables: drawables,
        resumeBeforeStop: resumeBeforeRelease
      )
    }
  }

  // MARK: - Media Loading

  /// Loads media into the player, replacing whatever was previously loaded.
  ///
  /// `media` is declared `sending`, so callers can construct a ``Media``
  /// on any actor or task and hand it off to this main-actor method
  /// without a copy. The compiler enforces the transfer: the caller
  /// cannot keep using the transferred reference after the call.
  public func load(_ media: sending Media) {
    currentMedia = media
    resetMediaDerivedState()
    // No `markLibraryStop()` here: setting media on a *started* handle
    // replaces the input seamlessly — libVLC 4 emits `MediaStopping` for
    // the interrupted input but the player never leaves the started
    // state, so no `Stopped` ever arrives to consume the flag. A mark
    // here goes stale and silently swallows the new media's genuine
    // natural end. (An explicit `stop()` before `load()` records its own
    // flag, and its in-flight `Stopped` consumes it — see
    // ``PlaybackEndCoordinator/clearForHandleReplacement()``.)
    libvlc_media_player_set_media(pointer, media.pointer)
    // No eager `refreshTracks()` here. The track list isn't populated
    // until libVLC emits `ESAdded` events after the demuxer opens, so
    // the `.tracksChanged` / `.mediaChanged` handlers refresh from a
    // single source of truth.
    notifyMediaDependentObservables()
  }

  // MARK: - Playback Control

  /// Loads media and starts playback in one step.
  /// - Throws: ``VLCError/playbackFailed(reason:)`` if playback cannot
  ///   start, or ``VLCError/operationFailed(_:)`` if a selected renderer
  ///   cannot be applied to a replacement native player.
  public func play(_ media: sending Media) throws(VLCError) {
    if shouldReplaceNativePlayerBeforePlaybackLoad {
      let resumeBeforeRelease = pauseTransition == .pausing || nativePlaybackState == .paused
      currentMedia = media
      resetMediaDerivedState()
      try replaceNativePlayerForDrawablePlayback(
        target: drawable,
        resumeBeforeRelease: resumeBeforeRelease
      )
    } else {
      load(media)
    }
    try play()
  }

  /// Creates media from a direct media URL and starts playback.
  ///
  /// This does not expand playlist container URLs such as `.pls` or
  /// classic `.m3u`; use ``MediaListPlayer`` or resolve those files to
  /// an inner stream URL first. HLS `.m3u8` URLs are valid here because
  /// they are streaming manifests.
  /// - Throws: ``VLCError/mediaCreationFailed(source:)``,
  ///   ``VLCError/playbackFailed(reason:)``, or
  ///   ``VLCError/operationFailed(_:)`` if a selected renderer cannot be
  ///   applied to a replacement native player.
  public func play(url: URL) throws(VLCError) {
    try play(Media(url: url))
  }

  /// Starts playback.
  /// - Throws: ``VLCError/playbackFailed(reason:)`` if playback cannot
  ///   start, or ``VLCError/operationFailed(_:)`` if a selected renderer
  ///   cannot be applied to a replacement native player.
  public func play() throws(VLCError) {
    try prepareDrawableForPlayback()
    didReachEnd = false
    if libvlc_media_player_play(pointer) == -1 {
      publishPlaybackIntent(false)
      let reason = libvlc_errmsg().map { String(cString: $0) } ?? "unknown"
      throw .playbackFailed(reason: reason)
    }
    nativePlayerHasStartedPlayback = true
    publishPlaybackIntent(true)
  }

  /// Pauses playback.
  ///
  /// If libVLC is visually playing but has not yet reached a stable,
  /// pausable state, SwiftVLC keeps the pause request pending and issues
  /// it once the native player reports that pausing is safe. With real
  /// audio output, the first audio timestamp must also have advanced
  /// beyond zero; pausing before that point can leave libVLC's aout
  /// stream with stale pause timing.
  public func pause() {
    _ = issuePause()
  }

  /// Resumes playback from pause.
  public func resume() {
    _ = issueResume()
  }

  @discardableResult
  func issuePause() -> Bool {
    guard pauseTransition == nil else {
      deferredPauseCommand = .pause
      publishPlaybackIntent(false)
      return false
    }
    switch state {
    case .playing:
      break
    case .opening, .buffering:
      deferredPauseCommand = .pause
      publishPlaybackIntent(false)
      return false
    case .paused:
      publishPlaybackIntent(false)
      return false
    default:
      return false
    }
    refreshNativeStateIfNeeded()
    guard isPausable, canIssueNativePause else {
      deferredPauseCommand = .pause
      publishPlaybackIntent(false)
      return false
    }

    pauseTransition = .pausing
    deferredPauseCommand = nil
    publishPlaybackIntent(false)
    libvlc_media_player_set_pause(pointer, 1)
    return true
  }

  @discardableResult
  func issueResume() -> Bool {
    guard pauseTransition == nil else {
      deferredPauseCommand = .resume
      publishPlaybackIntent(true)
      return true
    }
    if deferredPauseCommand == .pause {
      deferredPauseCommand = nil
      publishPlaybackIntent(true)
      return true
    }
    cancelPendingPause()
    let nativeState = nativePlaybackState
    guard nativeState == .paused else {
      if state == .paused, nativeState.isActive {
        publishPlaybackState(nativeState)
        publishPlaybackIntent(true)
        return true
      }
      if state.isActive {
        publishPlaybackIntent(true)
        return true
      }
      return false
    }

    pauseTransition = .resuming
    deferredPauseCommand = nil
    publishPlaybackIntent(true)
    libvlc_media_player_set_pause(pointer, 0)
    return true
  }

  func cancelPendingPause() {
    if deferredPauseCommand == .pause {
      deferredPauseCommand = nil
      publishPlaybackIntent(true)
    }
  }

  var shouldResumeForExternalPlayRequest: Bool {
    pauseTransition == .pausing
      || state == .paused
      || (!isPlaybackRequestedActive && state.isActive)
      || nativePlaybackState == .paused
  }

  /// Toggles between playing and paused, or starts playback from an
  /// idle or stopped state. Pause requests during opening or buffering
  /// are queued until libVLC reaches a stable pausable state. No-op in
  /// terminal or invalid transient states (`.stopping`, `.error`).
  ///
  /// Dispatches through explicit pause/resume requests using the
  /// observed ``state`` and the current playback intent, rather than
  /// calling `libvlc_media_player_pause` (which is itself a toggle). The
  /// raw toggle is unsafe mid-transition: interleaving a pause-toggle
  /// with the audio output's opening path corrupts
  /// `stream->timing.pause_date` and trips the upstream assertion
  /// `stream->timing.pause_date == VLC_TICK_INVALID` in
  /// `src/audio_output/dec.c:876`, killing the process. This can happen
  /// when a user taps Play/Pause immediately after a
  /// `.task { try? player.play(url:) }` begins.
  public func togglePlayPause() {
    switch state {
    case .idle, .stopped:
      try? play()
    case .playing, .opening, .buffering, .paused:
      if isPlaybackRequestedActive {
        pause()
      } else {
        resume()
      }
    case .stopping, .error:
      // There is no stable playback target for a pause/resume command.
      break
    }
  }

  /// Stops playback asynchronously.
  ///
  /// The native stop completes later, signalled by the
  /// `.stateChanged(.stopped)` event — use ``stopAndWait()`` when
  /// teardown must not race the audio/video output drain (for example
  /// before deactivating a shared `AVAudioSession`).
  public func stop() {
    if pauseTransition == .pausing || nativePlaybackState == .paused {
      libvlc_media_player_set_pause(pointer, 0)
    }
    pauseTransition = nil
    deferredPauseCommand = nil
    publishPlaybackIntent(false)
    if nativePlayerHasHostedDrawable {
      nativePlayerNeedsReplacementBeforePlayback = true
      needsDrawableRebindForPlayback = true
    } else {
      needsDrawableRebindForPlayback = drawable != nil
    }
    // The state read and the mark are not atomic against the event
    // thread: a natural end's `Stopped` can land in between, consuming
    // nothing and leaving this mark stale — which costs exactly one
    // suppressed natural end on the next session before the flag is
    // consumed. The window is microseconds wide and the failure
    // self-heals; closing it would need a session generation token
    // threaded through the callback for no practical gain.
    switch nativePlaybackState {
    case .idle, .stopped, .error:
      break
    default:
      endCoordinator.markLibraryStop()
    }
    libvlc_media_player_stop_async(pointer)
  }

  // MARK: - External Tracks

  /// Adds an external subtitle or audio file to the player.
  ///
  /// - Parameters:
  ///   - url: URL of the external track file (must use a valid scheme like `file://`).
  ///   - type: Whether this is a subtitle or audio track.
  ///   - select: If `true`, the track is selected immediately when loaded.
  /// - Throws: `VLCError.operationFailed` if the track cannot be added.
  public func addExternalTrack(from url: URL, type: MediaSlaveType, select: Bool = true) throws(VLCError) {
    let uri = url.absoluteString
    guard libvlc_media_player_add_slave(pointer, type.cValue, uri, select) == 0 else {
      throw .operationFailed("Add external \(type) track")
    }
  }

  // MARK: - Track Selection

  private func selectTrack(_ track: Track?, type: TrackType) {
    if let track {
      guard let cTrack = libvlc_media_player_get_track_from_id(pointer, track.id) else {
        return
      }
      libvlc_media_player_select_track(pointer, cTrack)
      libvlc_media_track_release(cTrack)
    } else {
      libvlc_media_player_unselect_track_type(pointer, type.cValue)
    }
    // No eager refresh here. libVLC emits `ESSelected` / `ESUpdated`
    // once the new selection settles (typically <10ms), and the event
    // handler's `refreshTracks()` is the single source of truth. An
    // eager refresh would race libVLC's internal state and briefly
    // show stale `isSelected` flags.
  }

  // MARK: - Video

  func applyAspectRatio() {
    if let ratioString = aspectRatio.vlcString {
      ratioString.withCString { cstr in
        libvlc_video_set_aspect_ratio(pointer, cstr)
      }
    } else {
      libvlc_video_set_aspect_ratio(pointer, nil)
    }

    switch aspectRatio {
    case .default:
      libvlc_video_set_scale(pointer, 0) // auto
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .ratio:
      // Explicitly reset the fit mode so a prior `.fill` (cover) can't
      // override the new aspect ratio visually.
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .fill:
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_larger)
    }
  }

  // MARK: - Track Refresh

  func refreshTracks() {
    audioTracks = fetchTracks(type: .audio)
    videoTracks = fetchTracks(type: .video)
    subtitleTracks = fetchTracks(type: .subtitle)
    withMutation(keyPath: \.selectedAudioTrack) {}
    withMutation(keyPath: \.selectedSubtitleTrack) {}
  }

  private func fetchTracks(type: TrackType) -> [Track] {
    guard let tracklist = libvlc_media_player_get_tracklist(pointer, type.cValue, false) else {
      return []
    }
    defer { libvlc_media_tracklist_delete(tracklist) }

    let count = libvlc_media_tracklist_count(tracklist)
    return (0..<count).compactMap { i in
      libvlc_media_tracklist_at(tracklist, i).map { Track(from: $0) }
    }
  }
}
