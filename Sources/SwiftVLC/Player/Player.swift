import CLibVLC
import Foundation
import Observation

/// An observable media player.
///
/// `Player` wraps `libvlc_media_player_t` with `@Observable` and
/// `@MainActor`, so SwiftUI views update in response to libVLC state
/// without a publisher adapter.
///
/// ```swift
/// struct PlayerView: View {
///     @State private var player = Player()
///
///     var body: some View {
///         VideoView(player)
///         Text(player.state.description)
///         Button(player.isPlaying ? "Pause" : "Play") {
///             player.togglePlayPause()
///         }
///     }
/// }
/// ```
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

  // MARK: - Bindable Properties

  /// Fractional playback position (0.0...1.0). Setting this seeks.
  public var position: Double {
    get {
      access(keyPath: \.position)
      return _position
    }
    set {
      withMutation(keyPath: \.position) {
        _position = newValue
        libvlc_media_player_set_position(pointer, newValue, /* fast */ false)
      }
      // libVLC doesn't reliably emit `MediaPlayerTimeChanged` after a
      // `set_position`, especially while paused, so `currentTime` appears
      // stuck at its pre-seek value. Update optimistically when duration
      // is known; the subsequent timeChanged event refines the estimate
      // with libVLC's post-seek frame timestamp.
      if let dur = duration {
        currentTime = dur * newValue
      }
    }
  }

  /// Volume level, normalized. `0.0` is silent, `1.0` is 100%. Values
  /// above `1.0` amplify, up to `1.25` (125%).
  ///
  /// Backed by a shadow `_volume` instead of a live libVLC read.
  /// Before the audio output is initialized `libvlc_audio_get_volume`
  /// returns a negative sentinel (`-100` on libVLC 4.0), which would
  /// surface in the UI as `-100%` even while the user is hearing audio
  /// at the default level. The shadow starts at `1.0` and is refreshed
  /// from the native player on each state transition, once libVLC's
  /// audio output can be trusted.
  public var volume: Float {
    get {
      access(keyPath: \.volume)
      return _volume
    }
    set {
      withMutation(keyPath: \.volume) {
        _volume = max(0, newValue)
        libvlc_audio_set_volume(pointer, Int32(_volume * 100))
      }
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

  /// Playback rate. `1.0` is normal speed, `0.5` is half, `2.0` is
  /// double. Any positive rate is accepted; the practical range is
  /// `0.25` to `4.0` before audio/video sync degrades.
  ///
  /// This setter discards libVLC's rejection signal so a slider binding
  /// never throws. Call ``setRate(_:)`` instead when the UI needs to
  /// react to rejection. Live HLS and RTSP streams often reject
  /// non-`1.0` rates, and `setRate(_:)` throws
  /// ``VLCError/operationFailed(_:)`` in that case.
  public var rate: Float {
    get {
      access(keyPath: \.rate)
      return libvlc_media_player_get_rate(pointer)
    }
    set {
      try? setRate(newValue)
    }
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
  public func setRate(_ newRate: Float) throws(VLCError) {
    let rc = withMutation(keyPath: \.rate) {
      libvlc_media_player_set_rate(pointer, newRate)
    }
    if rc != 0 {
      throw .operationFailed("Set rate to \(newRate)")
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
  public var audioDelay: Duration {
    get {
      access(keyPath: \.audioDelay)
      return .microseconds(libvlc_audio_get_delay(pointer))
    }
    set {
      _ = withMutation(keyPath: \.audioDelay) {
        libvlc_audio_set_delay(pointer, newValue.microseconds)
      }
    }
  }

  /// Subtitle delay relative to video. Positive values delay subtitles (make them appear later).
  public var subtitleDelay: Duration {
    get {
      access(keyPath: \.subtitleDelay)
      return .microseconds(libvlc_video_get_spu_delay(pointer))
    }
    set {
      _ = withMutation(keyPath: \.subtitleDelay) {
        libvlc_video_set_spu_delay(pointer, newValue.microseconds)
      }
    }
  }

  /// Subtitle text scale factor (1.0 = 100%, 0.5 = 50%, 2.0 = 200%).
  /// Clamped to [0.1, 5.0] by libVLC.
  public var subtitleTextScale: Float {
    get {
      access(keyPath: \.subtitleTextScale)
      return libvlc_video_get_spu_text_scale(pointer)
    }
    set {
      withMutation(keyPath: \.subtitleTextScale) {
        libvlc_video_set_spu_text_scale(pointer, newValue)
      }
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
  /// with the old style. The `Marquee` setters briefly write a different
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
    DispatchQueue.global(qos: .utility).async {
      bridge.invalidate()
      libvlc_media_player_stop_async(p)
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
    // mid-deref of the old `drawable-nsobject` pointer. `previous`
    // keeps the old view alive until this function returns, by which
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

  func prepareDrawableForPlayback() {
    if nativePlayerNeedsReplacementBeforePlayback {
      replaceNativePlayerForDrawablePlayback(target: drawable)
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

  private func replaceNativePlayerForDrawablePlayback(target: AnyObject?) {
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

    releaseNativePlayer(oldPointer, retaining: retainedDrawables)
    notifyMediaDependentObservables()
  }

  private func releaseNativePlayer(
    _ nativePlayer: OpaquePointer,
    retaining drawables: [AnyObject] = []
  ) {
    nonisolated(unsafe) let nativePlayer = nativePlayer
    nonisolated(unsafe) let drawables = drawables
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_player_set_nsobject(nativePlayer, nil)
      libvlc_media_player_stop_async(nativePlayer)
      libvlc_media_player_release(nativePlayer)
      _ = drawables
    }
  }

  // MARK: - Media Loading

  /// Loads media into the player, replacing whatever was previously loaded.
  ///
  /// `media` is declared `sending`, so callers can construct a ``Media``
  /// on any actor or task and hand it off to this main-actor method
  /// without a copy. The compiler enforces the transfer: the caller
  /// cannot retain the original reference after the call.
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
  /// - Throws: `VLCError.playbackFailed` if playback cannot start.
  public func play(_ media: sending Media) throws(VLCError) {
    load(media)
    try play()
  }

  /// Creates media from a direct media URL and starts playback.
  ///
  /// This does not expand playlist container URLs such as `.pls` or
  /// classic `.m3u`; use ``MediaListPlayer`` or resolve those files to
  /// an inner stream URL first. HLS `.m3u8` URLs are valid here because
  /// they are streaming manifests.
  /// - Throws: `VLCError.mediaCreationFailed` or `VLCError.playbackFailed`.
  public func play(url: URL) throws(VLCError) {
    try play(Media(url: url))
  }

  /// Starts playback.
  /// - Throws: `VLCError.playbackFailed` if playback cannot start.
  public func play() throws(VLCError) {
    prepareDrawableForPlayback()
    if libvlc_media_player_play(pointer) == -1 {
      publishPlaybackIntent(false)
      let reason = libvlc_errmsg().map { String(cString: $0) } ?? "unknown"
      throw .playbackFailed(reason: reason)
    }
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
  /// naked toggle is unsafe mid-transition: interleaving a pause-toggle
  /// with the audio output's opening path corrupts
  /// `stream->timing.pause_date` and trips the upstream assertion
  /// `stream->timing.pause_date == VLC_TICK_INVALID` in
  /// `src/audio_output/dec.c:876`, killing the process. The usual repro
  /// is a user tapping Play/Pause immediately after a
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
  /// No-op when the media is not seekable; observe ``isSeekable``
  /// before exposing scrub controls. The seek is asynchronous. Watch
  /// ``currentTime`` or the ``PlayerEvent/timeChanged(_:)`` event for
  /// completion.
  public func seek(to time: Duration) {
    libvlc_media_player_set_time(pointer, time.milliseconds, /* fast */ false)
    // Same optimistic update as the `position` setter: libVLC doesn't
    // always emit `MediaPlayerTimeChanged` after a seek (especially
    // while paused), so the published `currentTime` would appear stuck.
    // The subsequent timeChanged event refines this with libVLC's
    // post-seek frame timestamp.
    currentTime = time
  }

  /// Seeks by a relative offset from the current position.
  ///
  /// Negative offsets rewind, positive offsets fast-forward. Has no effect
  /// if the media is not seekable.
  public func seek(by offset: Duration) {
    libvlc_media_player_jump_time(pointer, offset.milliseconds)
    // Optimistic `currentTime` update for the same reason as `seek(to:)`.
    // Clamp to [0, duration] so the published value can never go
    // negative or past the end while libVLC catches up.
    var target = currentTime + offset
    if target < .zero {
      target = .zero
    } else if let dur = duration, target > dur {
      target = dur
    }
    currentTime = target
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

  func _handleEventForTesting(_ event: PlayerEvent) {
    handleEvent(event)
  }

  func _hasDeferredPauseForTesting() -> Bool {
    deferredPauseCommand == .pause
  }

  func _setStateForTesting(
    state: PlayerState? = nil,
    isPlaybackRequestedActive: Bool? = nil,
    currentTime: Duration? = nil,
    duration: Duration? = nil,
    position: Double? = nil,
    isSeekable: Bool? = nil,
    isPausable: Bool? = nil
  ) {
    if let state {
      self.state = state
      publishPlaybackIntent(state.isActive)
    }
    if let isPlaybackRequestedActive {
      publishPlaybackIntent(isPlaybackRequestedActive)
    }
    if let currentTime {
      self.currentTime = currentTime
    }
    if let duration {
      self.duration = duration
    }
    if let position {
      _position = position
    }
    if let isSeekable {
      self.isSeekable = isSeekable
    }
    if let isPausable {
      self.isPausable = isPausable
    }
  }
}
