#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
import CLibVLC
import Dispatch
import Foundation
import Synchronization

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
  /// Synchronizes playback state just before AVKit transitions into
  /// Picture in Picture, emits ``PiPEvent/willStart``, and clears any
  /// stale stop reason left by a previous failed or aborted attempt.
  public nonisolated func pictureInPictureControllerWillStartPictureInPicture(
    _ avController: AVPictureInPictureController
  ) {
    let identity = ObjectIdentifier(avController)
    let mediaGeneration = callbackSnapshot.withLock { $0.playbackGeneration }
    pipMainActorAsync { [weak self] in
      // Rejected unless it comes from the installed controller: the hop means
      // a controller replaced in the meantime can still deliver, and its
      // lifecycle describes a session that is over.
      guard let self, isCurrentAVController(identity) else { return }
      clearUnownedStopReasonBeforeStart()
      // Auto-PiP starts arrive from AVKit without start() or an intent
      // transition — last chance to issue the deferred session
      // activation before the PiP window owns playback.
      activateAudioSessionIfNeeded()
      syncPlaybackStateForPictureInPicture()
      invalidatePictureInPicturePlaybackState()
      publishPiPEvent(.willStart, mediaGeneration: mediaGeneration)
    }
  }

  /// Mirrors AVKit's active flag into Observation so SwiftUI can keep
  /// button labels and status UI in sync with system-driven PiP
  /// changes, and emits ``PiPEvent/didStart``.
  public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _ avController: AVPictureInPictureController
  ) {
    let identity = ObjectIdentifier(avController)
    let mediaGeneration = callbackSnapshot.withLock { $0.playbackGeneration }
    pipMainActorAsync { [weak self] in
      // Rejected unless it comes from the installed controller: the hop means
      // a controller replaced in the meantime can still deliver, and its
      // lifecycle describes a session that is over.
      guard let self, isCurrentAVController(identity) else { return }
      clearUnownedStopReasonBeforeStart()
      syncPlaybackStateForPictureInPicture()
      invalidatePictureInPicturePlaybackState()
      updatePiPActive(true)
      publishPiPEvent(.didStart, mediaGeneration: mediaGeneration)
    }
  }

  /// Emits ``PiPEvent/willStop(reason:)`` with the best-known reason at
  /// this instant. AVKit does not document whether the restore callback
  /// precedes this method, so the reason here may still be
  /// ``PiPStopReason/userClosed`` for a restore-driven stop; the reason
  /// on the matching `didStop` is authoritative.
  public nonisolated func pictureInPictureControllerWillStopPictureInPicture(
    _ avController: AVPictureInPictureController
  ) {
    let identity = ObjectIdentifier(avController)
    let mediaGeneration = callbackSnapshot.withLock { $0.playbackGeneration }
    pipMainActorAsync { [weak self] in
      // Rejected unless it comes from the installed controller: the hop means
      // a controller replaced in the meantime can still deliver, and its
      // lifecycle describes a session that is over.
      guard let self, isCurrentAVController(identity) else { return }
      publishPiPEvent(
        .willStop(reason: resolveWillStopReason()),
        mediaGeneration: mediaGeneration
      )
    }
  }

  /// Mirrors AVKit's active flag into Observation when PiP exits from
  /// either our own controls or the system's close affordance, and
  /// emits ``PiPEvent/didStop(reason:)`` with the resolved stop reason
  /// (see ``PiPController/pipEvents``), consuming the pending reason.
  public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _ avController: AVPictureInPictureController
  ) {
    let identity = ObjectIdentifier(avController)
    let mediaGeneration = callbackSnapshot.withLock { $0.playbackGeneration }
    pipMainActorAsync { [weak self] in
      // Rejected unless it comes from the installed controller: the hop means
      // a controller replaced in the meantime can still deliver, and its
      // lifecycle describes a session that is over.
      guard let self, isCurrentAVController(identity) else { return }
      let reason = resolveStopReason()
      updatePiPActive(false)
      publishPiPEvent(.didStop(reason: reason), mediaGeneration: mediaGeneration)
    }
  }

  /// How long ``PiPController/onRestoreUserInterface`` has to answer before
  /// AVKit is told the restore did not complete.
  ///
  /// The hook is host application code performing a UI transition, so it should
  /// answer in well under this. The bound exists so a hook that never answers
  /// cannot stall PiP teardown indefinitely, not to police a slow one — hence a
  /// ceiling generous enough that a legitimate restore is never cut short.
  ///
  /// Overridable so the bound itself can be tested without a ten second wait.
  /// Production never changes it.
  static var restoreCompletionTimeout: Duration = .seconds(10)

  /// Called when the user taps the PiP window's restore ("return to app")
  /// control. Forwards to ``PiPController/onRestoreUserInterface`` so the
  /// host app can bring its player UI back, then completes the AVKit
  /// transition. If no hook is set, completes immediately.
  ///
  /// The close (X) button does **not** route through here — it fires only
  /// the will-stop/did-stop callbacks (resolving to
  /// ``PiPStopReason/userClosed``) — which is how callers distinguish
  /// "restore" from "close".
  public nonisolated func pictureInPictureController(
    _ avController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
  ) {
    let identity = ObjectIdentifier(avController)
    pipMainActorAsync { [weak self] in
      // Rejected unless it comes from the installed controller: the hop means
      // a controller replaced in the meantime can still deliver, and its
      // lifecycle describes a session that is over.
      //
      // AVKit is owed this completion handler either way. Returning without
      // calling it leaves the teardown it drives unresolved, so a rejected
      // callback answers `false` — nothing was restored — rather than nothing
      // at all. The same applies when `self` has already gone.
      guard let self, isCurrentAVController(identity) else {
        completionHandler(false)
        return
      }
      // Record the reason before the host app's restore hook runs, so
      // the stop delegate callbacks see it no matter how AVKit orders
      // them relative to the hook's completion.
      notePendingStopReason(.restoreRequested)
      guard let onRestoreUserInterface else {
        completionHandler(true)
        return
      }

      // AVKit's handler must run exactly once. The hook is host application
      // code: it can answer twice, or never. Answering twice invokes a system
      // completion handler more than once; never answering leaves PiP teardown
      // waiting with no way out, which is the worse of the two because nothing
      // surfaces it.
      //
      // The latch is read and written only on the main actor — both the hook's
      // callback and the timeout below are `@MainActor` — so a plain box is
      // enough.
      let answered = RestoreAnswerLatch()
      let answer: @MainActor @Sendable (Bool) -> Void = { restored in
        guard !answered.value else { return }
        answered.value = true
        // Nothing left to bound. Without this the sleeping task, and the
        // completion closure it retains, stay alive for the full timeout after
        // even an immediate restore.
        answered.timeout?.cancel()
        answered.timeout = nil
        completionHandler(restored)
      }

      onRestoreUserInterface(answer)

      // A hook that answered synchronously needs no timeout at all; starting
      // one here would create a task whose only job is to wake up and find the
      // latch already closed.
      guard !answered.value else { return }

      answered.timeout = Task { @MainActor in
        try? await Task.sleep(for: Self.restoreCompletionTimeout)
        guard !Task.isCancelled else { return }
        // `false`: the interface was not restored within the bound. Reporting
        // success would tell AVKit a restore happened that did not.
        answer(false)
      }
    }
  }

  /// `AVPictureInPictureControllerDelegate` hook. Emits
  /// ``PiPEvent/failedToStart(_:)`` carrying the AVKit error, records
  /// ``PiPStopReason/failure`` for any stop callbacks that follow, and
  /// resyncs the observed flags so the UI doesn't stay stuck in a stale
  /// "starting" state.
  public nonisolated func pictureInPictureController(
    _ avController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    let identity = ObjectIdentifier(avController)
    let mediaGeneration = callbackSnapshot.withLock { $0.playbackGeneration }
    pipMainActorAsync { [weak self] in
      // Rejected unless it comes from the installed controller: the hop means
      // a controller replaced in the meantime can still deliver, and its
      // lifecycle describes a session that is over.
      guard let self, isCurrentAVController(identity) else { return }
      updatePiPActive(false)
      publishPiPEvent(.failedToStart(error), mediaGeneration: mediaGeneration)
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
/// one hops to the main actor before reading or mutating the owner.
final class PiPPlaybackDelegateProxy: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
  /// `@unchecked Sendable` is the narrow concession that lets AVKit
  /// hand the proxy between threads. The owner field is the only state,
  /// it's `weak` (ARC-atomic in Swift), and every read happens inside
  /// a `pipMainActorAsync` enqueue onto the main actor, or through the
  /// lock-protected `PiPCallbackSnapshot` for the two queries AVKit needs
  /// answered synchronously. Neither path blocks the callback thread on
  /// main, so owner access is serialized without a deadlock edge.
  weak var owner: PiPController?

  func pictureInPictureController(
    _ avController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    pipMainActorAsync { [weak self] in
      self?.owner?.handleSetPlaying(playing)
    }
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ avController: AVPictureInPictureController
  ) -> CMTimeRange {
    resolveTimeRangeForPlayback()
  }

  /// The body of the time-range query, separated from AVKit's entry point so
  /// forward-progress tests can drive it without constructing an
  /// `AVPictureInPictureController` (which AVKit refuses to let tests make).
  ///
  /// Answered without hopping to the main actor: AVKit calls this from
  /// arbitrary threads, and blocking one of them on main is what lets a
  /// teardown already waiting on that thread deadlock.
  func resolveTimeRangeForPlayback() -> CMTimeRange {
    guard let snapshot = currentCallbackSnapshot() else { return .invalid }
    return Self.timeRange(for: snapshot)
  }

  /// Reads the whole snapshot under a single lock acquisition, so the pointer
  /// and timebase a query works with always belong to the same generation.
  private func currentCallbackSnapshot() -> PiPCallbackSnapshot? {
    // `Mutex` is non-copyable, so the lock is used in place rather than bound.
    guard let snapshot = owner?.callbackSnapshot.withLock({ $0 }) else { return nil }
    return snapshot.isAttached ? snapshot : nil
  }

  /// Assembles the reported range from one generation's handle and timebase.
  ///
  /// libVLC is queried *after* the lock is released — the snapshot lock must
  /// never be held across a call that could itself block.
  static func timeRange(for snapshot: PiPCallbackSnapshot) -> CMTimeRange {
    guard let playerPointer = snapshot.playerPointer else { return .invalid }
    let currentTime = snapshot.controlTimebase.map(CMTimebaseGetTime) ?? .zero
    return nativePlaybackTimeRange(
      playerPointer: playerPointer,
      currentTime: currentTime
    )
  }

  /// Queries the native player without consulting Swift-side media mirrors.
  static func nativePlaybackTimeRange(
    playerPointer: OpaquePointer,
    currentTime: CMTime = .zero
  ) -> CMTimeRange {
    playbackTimeRange(
      playerPointer: playerPointer,
      currentTime: currentTime,
      getSnapshot: { player in
        retainedMediaLengthSnapshot(
          playerPointer: player,
          atomicSnapshotAvailable: swiftvlc_media_length_snapshot_available(),
          getAtomicSnapshot: { player in
            var native = swiftvlc_media_player_media_length_snapshot_t()
            guard
              swiftvlc_media_player_get_media_length_snapshot_if_available(
                player,
                &native
              ),
              let media = native.media
            else { return nil }
            return (media: media, length: native.length)
          },
          getRetainedMedia: { libvlc_media_player_get_media($0) },
          getMediaDuration: { libvlc_media_get_duration($0) }
        )
      },
      releaseMedia: { libvlc_media_release($0) }
    )
  }

  /// Reads one retained media identity and its matching length. New pinned
  /// binaries capture both under the player lock. Older binaries retain the
  /// media first and read duration from that exact object; they never combine
  /// `get_media` with the independently locked player-length API.
  static func retainedMediaLengthSnapshot(
    playerPointer: OpaquePointer,
    atomicSnapshotAvailable: Bool,
    getAtomicSnapshot: (OpaquePointer) -> (media: OpaquePointer, length: Int64)?,
    getRetainedMedia: (OpaquePointer) -> OpaquePointer?,
    getMediaDuration: (OpaquePointer) -> Int64
  ) -> (media: OpaquePointer, length: Int64)? {
    if atomicSnapshotAvailable {
      return getAtomicSnapshot(playerPointer)
    }

    guard let media = getRetainedMedia(playerPointer) else { return nil }
    return (media: media, length: getMediaDuration(media))
  }

  /// Maps one retained media/length pair and balances its media retain.
  static func playbackTimeRange(
    playerPointer: OpaquePointer,
    currentTime: CMTime = .zero,
    getSnapshot: (OpaquePointer) -> (media: OpaquePointer, length: Int64)?,
    releaseMedia: (OpaquePointer) -> Void
  ) -> CMTimeRange {
    guard let snapshot = getSnapshot(playerPointer) else { return .invalid }
    defer { releaseMedia(snapshot.media) }

    return playbackTimeRange(
      hasMedia: true,
      duration: snapshot.length > 0 ? .milliseconds(snapshot.length) : nil,
      currentTime: currentTime
    )
  }

  /// Maps SwiftVLC's media lifecycle onto AVKit's sample-buffer contract:
  /// invalid means there is no content, positive infinity means loaded
  /// live/indefinite content, and a positive duration means seekable VOD.
  static func playbackTimeRange(
    hasMedia: Bool,
    duration: Duration?,
    currentTime: CMTime = .zero
  ) -> CMTimeRange {
    guard hasMedia else { return .invalid }

    let durationSeconds = duration.map {
      Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
    } ?? 0

    guard durationSeconds > 0 else {
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    let nominalDuration = CMTime(seconds: durationSeconds, preferredTimescale: 1000)
    let nominalRange = CMTimeRange(
      start: .zero,
      duration: nominalDuration
    )
    guard currentTime.isNumeric else { return nominalRange }
    if CMTimeRangeContainsTime(nominalRange, time: currentTime) {
      return nominalRange
    }

    // AVKit requires every finite answer to contain the display layer's
    // current control-timebase value. At an end boundary (which Core Media
    // ranges exclude) or during a small event/timebase race, extend only the
    // reported edge needed to satisfy that contract.
    let tick = CMTime(value: 1, timescale: 1000)
    let start = CMTimeCompare(currentTime, .zero) < 0 ? currentTime : .zero
    let currentEnd = CMTimeAdd(currentTime, tick)
    let end = CMTimeCompare(currentEnd, nominalDuration) > 0
      ? currentEnd
      : nominalDuration
    return CMTimeRangeFromTimeToTime(start: start, end: end)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ avController: AVPictureInPictureController
  ) -> Bool {
    resolveIsPlaybackPaused()
  }

  /// The body of the paused query. See ``resolveTimeRangeForPlayback()`` for
  /// why it is split out.
  ///
  /// Snapshot read, no main-actor hop. Defaults to paused when nothing is
  /// attached so AVKit renders a stable UI while teardown drains.
  func resolveIsPlaybackPaused() -> Bool {
    guard let snapshot = currentCallbackSnapshot() else { return true }
    return !snapshot.isPlaybackActive
  }

  func pictureInPictureController(
    _ avController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    pipMainActorAsync { [weak self] in
      guard let owner = self?.owner else {
        completionHandler()
        return
      }
      owner.handleSkip(by: skipInterval, completion: completionHandler)
    }
  }

  func pictureInPictureController(
    _ avController: AVPictureInPictureController,
    didTransitionToRenderSize size: CMVideoDimensions
  ) {
    let identity = ObjectIdentifier(avController)
    pipMainActorAsync { [weak self] in
      // Now that this mutates conversion state, an outgoing controller's
      // render size must not be applied to its successor — the same identity
      // rule every other AVKit signal here follows.
      guard let owner = self?.owner, owner.isCurrentAVController(identity) else { return }
      owner.handleRenderSizeTransition(size)
    }
  }
}

/// Runs `body` on the main actor without blocking the calling thread.
///
/// AVKit invokes most of its callbacks from non-main threads and does not
/// need a return value from them. Blocking those threads on the main actor
/// closes a deadlock cycle: the main thread routinely waits on libVLC or
/// video-output teardown, and that teardown can be gated behind the very
/// callback thread that is now parked waiting for main. Enqueueing instead
/// removes the callback-waits-for-main edge, so no cycle can form.
///
/// Already on the main thread, `body` still runs synchronously — reordering
/// a callback relative to work the caller has already done would change
/// observable behaviour for no benefit.
/// Runs `body` on the main actor and waits, but only for `timeout`.
///
/// The escape hatch for the one callback that genuinely cannot be answered
/// from a snapshot: AppKit's close veto has to run main-actor UI work
/// (reparenting the replacement window) *before* it returns. Blocking is
/// unavoidable there, so the wait is bounded instead — if the main actor is
/// wedged behind teardown, the caller degrades to `fallback` rather than
/// joining the deadlock.
///
/// Everything else should use ``pipMainActorAsync`` or read a snapshot.
func pipMainActorSyncBounded<T: Sendable>(
  timeout: DispatchTimeInterval = .milliseconds(250),
  fallback: T,
  _ body: @escaping @MainActor @Sendable () -> T
) -> T {
  if Thread.isMainThread {
    return MainActor.assumeIsolated(body)
  }

  let state = Mutex(BoundedHopState<T>())
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.main.async {
    // The caller may already have given up. Running `body` then would perform
    // side effects for a result nobody will see — for the close veto that
    // means reparenting the replacement window *after* telling AppKit the
    // close was allowed. When the main actor is genuinely wedged, which is
    // the case this exists for, the closure has not started yet and this
    // check is what stops it.
    guard !state.withLock({ $0.abandoned }) else { return }
    let value = MainActor.assumeIsolated(body)
    state.withLock { $0.value = value }
    done.signal()
  }

  guard done.wait(timeout: .now() + timeout) == .success else {
    state.withLock { $0.abandoned = true }
    return fallback
  }
  // Unwraps exactly one level, so a `T` that is itself optional round-trips a
  // genuine `nil` instead of collapsing into `fallback`.
  guard let value = state.withLock({ $0.value }) else { return fallback }
  return value
}

/// Result slot for ``pipMainActorSyncBounded(timeout:fallback:_:)``.
private struct BoundedHopState<Value> {
  var value: Value?
  var abandoned = false
}

func pipMainActorAsync(_ body: @escaping @MainActor @Sendable () -> Void) {
  if Thread.isMainThread {
    MainActor.assumeIsolated(body)
    return
  }
  DispatchQueue.main.async {
    MainActor.assumeIsolated(body)
  }
}

/// A once-only latch for AVKit's restore completion handler.
///
/// Confined to the main actor: both writers — the host's restore hook callback
/// and the timeout — are `@MainActor`, so no synchronisation is needed beyond
/// that isolation. A class rather than a captured `var` because two closures
/// share it.
@MainActor
final class RestoreAnswerLatch {
  var value = false
  /// The bounded wait, held so the first answer can cancel it rather than
  /// leaving it sleeping — and retaining the completion closure — for the full
  /// timeout.
  var timeout: Task<Void, Never>?
}

#endif
