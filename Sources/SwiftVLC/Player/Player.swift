import CLibVLC
import Foundation
import Observation

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

  /// The currently loaded media.
  public internal(set) var currentMedia: Media?

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
  /// - Parameter newRate: Target rate. `1.0` is normal speed.
  /// - Throws: ``VLCError/operationFailed(_:)`` if libVLC rejects the rate.
  public func setRate(_ newRate: PlaybackRate) throws(VLCError) {
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

  /// Raw event stream for custom processing.
  /// Most consumers should use `@Observable` properties instead.
  public nonisolated var events: AsyncStream<PlayerEvent> {
    eventBridge.makeStream()
  }

  nonisolated var playbackIntentEvents: AsyncStream<Bool> {
    playbackIntentBridge.subscribe()
  }

  // MARK: - Internal

  @ObservationIgnored
  nonisolated(unsafe) var pointer: OpaquePointer // libvlc_media_player_t*
  let eventBridge: EventBridge
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
  private var drawableOwner: ObjectIdentifier?
  var needsDrawableRebindForPlayback = false
  private var nativePlayerHasHostedDrawable = false
  private var nativePlayerNeedsReplacementBeforePlayback = false
  private var retainedDrawablesUntilNativePlayerRelease: [AnyObject] = []
  var selectedRenderer: RendererItem?
  var nativePlayerHasStartedPlayback = false
  let instance: VLCInstance

  // MARK: - Lifecycle

  /// Creates a new player.
  /// - Parameter instance: The VLC instance to use.
  public init(instance: VLCInstance = .shared) {
    let p = Self.makeNativePlayer(instance: instance)
    pointer = p
    self.instance = instance
    eventBridge = EventBridge(
      eventManager: libvlc_media_player_event_manager(p)!
    )
    playbackIntentBridge = Broadcaster<Bool>(defaultBufferSize: 16)
    startEventConsumer()
  }

  private static func makeNativePlayer(instance: VLCInstance) -> OpaquePointer {
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
      bridge.invalidate()
      Self.stopNativePlayerBeforeRelease(p, resumeBeforeStop: resumeBeforeRelease)
      libvlc_media_player_release(p)
      _ = drawables
    }
  }

  // MARK: - Video Drawable

  /// Attaches (or detaches, when `nil`) the platform-native view that
  /// libVLC renders video into. `Player` holds the view strongly for
  /// the duration of the attachment so libVLC's raw `drawable-nsobject`
  /// pointer stays valid against asynchronous reads from the decode
  /// thread. Callers should normally use ``VideoView`` in SwiftUI; this
  /// is the lower-level API it builds on.
  func setDrawable(_ newDrawable: AnyObject?) {
    drawableOwner = newDrawable.map(ObjectIdentifier.init)
    applyDrawable(newDrawable)
  }

  func claimDrawableOwnership(_ owner: AnyObject) {
    drawableOwner = ObjectIdentifier(owner)
  }

  func releaseDrawableOwnership(_ owner: AnyObject) {
    guard isDrawableOwner(owner) else { return }
    drawableOwner = nil
    if isCurrentDrawable(owner) {
      applyDrawable(nil)
    }
  }

  func setDrawable(_ newDrawable: AnyObject, owner: AnyObject) {
    guard isDrawableOwner(owner) else { return }
    applyDrawable(newDrawable)
  }

  func clearDrawable(ifCurrent staleDrawable: AnyObject) {
    guard isCurrentDrawable(staleDrawable) else { return }
    if drawableOwner == ObjectIdentifier(staleDrawable) {
      drawableOwner = nil
    }
    setDrawable(nil)
  }

  func isCurrentDrawable(_ candidate: AnyObject) -> Bool {
    guard let drawable else { return false }
    return drawable === candidate
  }

  func isDrawableOwner(_ candidate: AnyObject) -> Bool {
    drawableOwner == ObjectIdentifier(candidate)
  }

  private func applyDrawable(_ newDrawable: AnyObject?) {
    // Bind the outgoing reference to a local so it outlives the libVLC
    // call. After the ivar is reassigned, ARC would otherwise release
    // the previous view immediately; the vout thread could still be
    // mid-deref of that `drawable-nsobject` pointer. `previous`
    // keeps the previous view alive until this function returns, by which
    // point libVLC has atomically swapped the variable.
    let previous = drawable
    if
      let previous,
      nativePlayerNeedsReplacementBeforePlayback,
      newDrawable.map({ previous !== $0 }) ?? true {
      retainedDrawablesUntilNativePlayerRelease.append(previous)
    }
    drawable = newDrawable
    if newDrawable != nil {
      nativePlayerHasHostedDrawable = true
    }
    libvlc_media_player_set_nsobject(
      pointer,
      newDrawable.map { Unmanaged.passUnretained($0).toOpaque() }
    )
    _ = previous
  }

  func prepareDrawableForPlayback() throws(VLCError) {
    if nativePlayerNeedsReplacementBeforePlayback {
      try replaceNativePlayerForDrawablePlayback(target: drawable)
      return
    }
    guard let target = drawable else { return }
    guard needsDrawableRebindForPlayback else { return }
    let owner = drawableOwner
    applyDrawable(nil)
    drawableOwner = owner
    applyDrawable(target)
    needsDrawableRebindForPlayback = false
  }

  private func replaceNativePlayerForDrawablePlayback(
    target: AnyObject?,
    resumeBeforeRelease: Bool = false
  )
    throws(VLCError) {
    let oldPointer = pointer
    let newPointer = Self.makeNativePlayer(instance: instance)
    guard let newEventManager = libvlc_media_player_event_manager(newPointer) else {
      libvlc_media_player_release(newPointer)
      preconditionFailure("Failed to access libVLC media player event manager.")
    }

    let playbackRate = libvlc_media_player_get_rate(oldPointer)
    let playerRole = libvlc_media_player_get_role(oldPointer)
    let audioDelay = libvlc_audio_get_delay(oldPointer)
    let subtitleDelay = libvlc_video_get_spu_delay(oldPointer)
    let subtitleScale = libvlc_video_get_spu_text_scale(oldPointer)
    let retainedDrawables = retainedDrawablesUntilNativePlayerRelease

    if let currentMedia {
      libvlc_media_player_set_media(newPointer, currentMedia.pointer)
    }
    guard libvlc_media_player_set_renderer(newPointer, selectedRenderer?.pointer) == 0 else {
      libvlc_media_player_release(newPointer)
      throw .operationFailed("Set renderer")
    }
    _ = libvlc_audio_set_volume(newPointer, Int32(_volume * 100))
    libvlc_audio_set_mute(newPointer, _isMuted ? 1 : 0)
    _ = libvlc_media_player_set_rate(newPointer, playbackRate)
    _ = libvlc_media_player_set_role(newPointer, UInt32(playerRole))
    _ = libvlc_audio_set_delay(newPointer, audioDelay)
    _ = libvlc_video_set_spu_delay(newPointer, subtitleDelay)
    libvlc_video_set_spu_text_scale(newPointer, subtitleScale)
    libvlc_media_player_set_equalizer(newPointer, _equalizer?.pointer)
    libvlc_media_player_set_nsobject(
      newPointer,
      target.map { Unmanaged.passUnretained($0).toOpaque() }
    )

    eventBridge.reattach(to: newEventManager)
    pointer = newPointer
    applyAspectRatio()

    retainedDrawablesUntilNativePlayerRelease.removeAll()
    nativePlayerNeedsReplacementBeforePlayback = false
    needsDrawableRebindForPlayback = false
    nativePlayerHasHostedDrawable = target != nil
    nativePlayerHasStartedPlayback = false

    releaseNativePlayer(
      oldPointer,
      retaining: retainedDrawables,
      resumeBeforeStop: resumeBeforeRelease
    )
    notifyMediaDependentObservables()
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
    libvlc_media_player_stop_async(pointer)
  }

  /// Seeks to an absolute time in the current media.
  ///
  /// Throws instead of silently ignoring invalid requests. Check
  /// ``isSeekable`` before exposing scrub controls. The native seek is
  /// asynchronous; SwiftVLC publishes the requested time immediately after
  /// validation so paused players update their UI even if libVLC does not
  /// emit a follow-up `timeChanged` event.
  ///
  /// - Throws: ``VLCError/invalidState(_:)`` if the current media is not
  ///   seekable, or ``VLCError/invalidInput(_:)`` if `time` is negative,
  ///   outside libVLC's millisecond range, or beyond known duration.
  public func seek(to time: Duration) throws(VLCError) {
    let milliseconds = try checkedSeekMilliseconds(for: time, parameter: "time")
    libvlc_media_player_set_time(pointer, milliseconds, /* fast */ false)
    currentTime = .milliseconds(milliseconds)
  }

  /// Seeks to a fractional position in the current media.
  ///
  /// `PlaybackPosition` clamps to `0.0 ... 1.0` on construction. This
  /// method still throws if the player does not yet know media duration or
  /// if the current media is not seekable.
  public func seek(to position: PlaybackPosition) throws(VLCError) {
    guard let duration else {
      throw .invalidState("duration is not known")
    }
    let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
    let target = checkedMilliseconds(for: position, durationMs: durationMs)
    try seek(to: .milliseconds(target))
  }

  /// Seeks by a relative offset from the current position.
  ///
  /// Negative offsets rewind, positive offsets fast-forward. The target is
  /// clamped to the known playable range after validating the offset.
  ///
  /// - Throws: ``VLCError/invalidState(_:)`` if the current media is not
  ///   seekable, or ``VLCError/invalidInput(_:)`` if the offset/current
  ///   time cannot be represented in libVLC's millisecond unit.
  public func seek(by offset: Duration) throws(VLCError) {
    guard isSeekable else {
      throw .invalidState("current media is not seekable")
    }

    let currentMs = try currentTime.checkedMilliseconds(parameter: "currentTime")
    let offsetMs = try offset.checkedMilliseconds(parameter: "offset")
    let targetResult = currentMs.addingReportingOverflow(offsetMs)
    guard !targetResult.overflow else {
      throw .invalidInput("offset is outside the supported millisecond range")
    }

    var targetMs = Swift.max(0, targetResult.partialValue)
    if let duration {
      let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
      targetMs = Swift.min(targetMs, durationMs)
    }

    libvlc_media_player_set_time(pointer, targetMs, /* fast */ false)
    currentTime = .milliseconds(targetMs)
  }

  private func checkedSeekMilliseconds(for time: Duration, parameter: String) throws(VLCError) -> Int64 {
    guard isSeekable else {
      throw .invalidState("current media is not seekable")
    }

    let milliseconds = try time.checkedNonnegativeMilliseconds(parameter: parameter)
    if let duration {
      let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
      guard milliseconds <= durationMs else {
        throw .invalidInput("\(parameter) must not exceed current media duration")
      }
    }
    return milliseconds
  }

  private func checkedMilliseconds(for position: PlaybackPosition, durationMs: Int64) -> Int64 {
    guard position.rawValue > 0 else { return 0 }
    guard position.rawValue < 1 else { return durationMs }

    let scaled = (Double(durationMs) * position.rawValue).rounded()
    guard scaled.isFinite, scaled > 0 else { return 0 }
    guard scaled < Double(Int64.max) else { return durationMs }
    return Swift.min(Int64(scaled), durationMs)
  }

  /// Pauses playback and advances one video frame.
  ///
  /// Requires the current media to be pausable (see ``isPausable``).
  /// Calling repeatedly yields frame-by-frame stepping.
  public func nextFrame() {
    libvlc_media_player_next_frame(pointer)
    // libVLC doesn't emit `MediaPlayerTimeChanged` after a next-frame
    // step while paused: the decoder advances one frame but the event
    // thread stays quiescent. Read the authoritative time directly so
    // `currentTime` reflects the step.
    let ms = libvlc_media_player_get_time(pointer)
    if ms >= 0 {
      currentTime = .milliseconds(ms)
    }
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

  private func applyAspectRatio() {
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
