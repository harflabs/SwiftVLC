import CLibVLC
import Foundation
import Synchronization

/// Owns work that must remain alive until one exact native media-player
/// handle has finished releasing.
///
/// A libVLC video output copies callback pointers and their opaque value when
/// it opens. Replacing or clearing the media-player variables does not revoke
/// a copy already in flight, so callback opaques cannot be reclaimed based on
/// the Swift `Player.pointer` (which may already name a successor) or on a
/// timeout. Release actions registered here run only after SwiftVLC and every
/// native list-player owner release this exact handle, so libVLC's final
/// release has joined its output teardown.
final class NativePlayerHandleLifetime: @unchecked Sendable {
  private struct State {
    var nativeOwnerCount = 1
    var initialOwnerEnded = false
    var isReleased = false
    var releaseActionsPerformed = false
    var releaseActions: [@Sendable () -> Void] = []
    var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private struct ReleaseCompletion {
    var actions: [@Sendable () -> Void] = []
  }

  private final class RetainedObjects: @unchecked Sendable {
    private struct Contents: @unchecked Sendable {
      var objects: [AnyObject]
    }

    private let contents: Mutex<Contents>

    init(_ objects: [AnyObject]) {
      contents = Mutex(Contents(objects: objects))
    }

    /// Moves the retained objects into a fresh box. The release action itself
    /// remains stored in its completion array until `perform` returns, so a
    /// second capture of the same box would still let that array perform the
    /// final release on the native teardown thread.
    func takeContents() -> RetainedObjects? {
      let objects = contents.withLock { contents -> [AnyObject] in
        let objects = contents.objects
        contents.objects = []
        return objects
      }
      return objects.isEmpty ? nil : RetainedObjects(objects)
    }
  }

  let pointer: OpaquePointer
  private let state = Mutex(State())

  init(pointer: OpaquePointer) {
    self.pointer = pointer
  }

  /// Registers an action for the end of this handle's native lifetime.
  /// Returns `false` if the handle had already ended; callers must not install
  /// new native callbacks in that case.
  @discardableResult
  func whenReleased(_ action: @escaping @Sendable () -> Void) -> Bool {
    let accepted = state.withLock { state -> Bool in
      guard !state.isReleased else { return false }
      state.releaseActions.append(action)
      return true
    }
    if !accepted {
      action()
    }
    return accepted
  }

  /// Accounts for one additional native owner of this exact media-player
  /// handle. The lease must be acquired before the native retain happens and
  /// ended only after the matching native release call returns.
  func acquireNativeOwnerLease() -> NativePlayerHandleLease {
    state.withLock { state in
      precondition(!state.isReleased, "Cannot retain a released native player handle")
      state.nativeOwnerCount += 1
    }
    return NativePlayerHandleLease(lifetime: self)
  }

  /// Ends SwiftVLC's initial ownership after its
  /// `libvlc_media_player_release` call returns. A media-list player can still
  /// own the same native handle, so this is not necessarily the end of the
  /// handle's lifetime.
  func initialOwnerDidRelease() {
    let completion = state.withLock { state -> ReleaseCompletion? in
      precondition(!state.initialOwnerEnded, "Initial native-player owner ended twice")
      state.initialOwnerEnded = true
      return Self.endOneNativeOwner(in: &state)
    }
    if let completion {
      perform(completion)
    }
  }

  fileprivate func leasedOwnerDidRelease() {
    let completion = state.withLock { state in
      Self.endOneNativeOwner(in: &state)
    }
    if let completion {
      perform(completion)
    }
  }

  /// Ends one native owner. Returns the release completion only when this was
  /// the final owner (the handle just reached release); returns `nil` while
  /// other owners remain, so callers skip `perform` until the terminal release.
  private static func endOneNativeOwner(in state: inout State) -> ReleaseCompletion? {
    precondition(state.nativeOwnerCount > 0, "Native-player owner count underflow")
    state.nativeOwnerCount -= 1
    guard state.nativeOwnerCount == 0 else { return nil }

    precondition(!state.isReleased, "Native player handle released twice")
    state.isReleased = true
    let completion = ReleaseCompletion(actions: state.releaseActions)
    state.releaseActions.removeAll()
    return completion
  }

  private func perform(_ completion: ReleaseCompletion) {
    for action in completion.actions {
      action()
    }
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      precondition(state.isReleased && !state.releaseActionsPerformed)
      state.releaseActionsPerformed = true
      let waiters = state.releaseWaiters
      state.releaseWaiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// Holds objects until every counted native owner has released the exact
  /// handle. This is intentionally tied to native ownership rather than the
  /// return of SwiftVLC's own release call: a media-list player may keep the
  /// player and its vout callbacks alive past that point.
  func retainUntilReleased(_ objects: [AnyObject]) {
    guard !objects.isEmpty else { return }
    let retained = RetainedObjects(objects)
    whenReleased { [retained] in
      guard let releaseOwner = retained.takeContents() else { return }
      if Thread.isMainThread {
        withExtendedLifetime(releaseOwner) {}
      } else {
        // The box commonly holds UIKit/AppKit drawables. Native ownership can
        // end on either teardown utility queue, but the final strong reference
        // must not deinitialize a platform view there. `takeContents` emptied
        // the release action's long-lived capture; this nested closure is now
        // the sole lifetime owner and drops it on the main queue after the
        // exact native lifetime has ended.
        DispatchQueue.main.async { [releaseOwner] in
          withExtendedLifetime(releaseOwner) {}
        }
      }
    }
  }

  func waitUntilReleased() async {
    if !releaseActionsPerformed {
      await withCheckedContinuation { continuation in
        let resumeImmediately = state.withLock { state -> Bool in
          guard !state.releaseActionsPerformed else { return true }
          state.releaseWaiters.append(continuation)
          return false
        }
        if resumeImmediately {
          continuation.resume()
        }
      }
    }

    // Retained UIKit/AppKit objects are moved to the main queue by their
    // release action. That action is always enqueued before
    // `releaseActionsPerformed` flips, so a main-queue fence proves their final
    // release has happened without ever blocking the main actor.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume()
      }
    }
  }

  private var releaseActionsPerformed: Bool {
    state.withLock { $0.releaseActionsPerformed }
  }

  var isReleased: Bool {
    state.withLock { $0.isReleased }
  }

  var nativeOwnerCount: Int {
    state.withLock { $0.nativeOwnerCount }
  }
}

/// A counted claim corresponding to one native retain of a media-player
/// handle. Ending a lease is explicit and idempotent. It deliberately does not
/// auto-end in `deinit`: losing the token before the native release would make
/// callbacks eligible for reclamation while native code can still invoke them.
final class NativePlayerHandleLease: @unchecked Sendable {
  private let lifetime: NativePlayerHandleLifetime
  private let didEnd = Mutex(false)

  fileprivate init(lifetime: NativePlayerHandleLifetime) {
    self.lifetime = lifetime
  }

  func endAfterNativeOwnerRelease() {
    let shouldEnd = didEnd.withLock { didEnd -> Bool in
      guard !didEnd else { return false }
      didEnd = true
      return true
    }
    if shouldEnd {
      lifetime.leasedOwnerDidRelease()
    }
  }
}

extension Player {
  /// Whether teardown must first cancel a native pause (including one whose
  /// async state event has not arrived yet). Capture this before clearing
  /// `pauseTransition`; otherwise a shutdown racing `.pausing` can skip the
  /// resume and stop libVLC while its audio output still has a pending pause.
  var shouldResumeNativePlayerBeforeStop: Bool {
    pauseTransition == .pausing || nativePlaybackState == .paused
  }

  func releaseNativePlayer(
    _ nativePlayer: OpaquePointer,
    lifetime: NativePlayerHandleLifetime,
    retaining drawables: [AnyObject] = [],
    resumeBeforeStop: Bool = false
  ) {
    precondition(lifetime.pointer == nativePlayer)
    lifetime.retainUntilReleased(drawables)
    nonisolated(unsafe) let nativePlayer = nativePlayer
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_player_set_nsobject(nativePlayer, nil)
      Self.stopNativePlayerBeforeRelease(nativePlayer, resumeBeforeStop: resumeBeforeStop)
      libvlc_media_player_release(nativePlayer)
      lifetime.initialOwnerDidRelease()
    }
  }

  nonisolated static func stopNativePlayerBeforeRelease(
    _ nativePlayer: OpaquePointer,
    resumeBeforeStop: Bool
  ) {
    if resumeBeforeStop || PlayerState(from: libvlc_media_player_get_state(nativePlayer)) == .paused {
      libvlc_media_player_set_pause(nativePlayer, 0)
    }
    libvlc_media_player_stop_async(nativePlayer)
  }

  var shouldReplaceNativePlayerBeforePlaybackLoad: Bool {
    guard currentMedia != nil else { return false }
    switch state {
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      return true
    case .idle, .stopped:
      break
    }

    switch nativePlaybackState {
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      return true
    case .idle, .stopped:
      return false
    }
  }
}

#if os(iOS) || os(macOS)
extension Player {
  /// Makes `registration` the sole display owner of the stable direct-PiP
  /// callback slot for the current native handle. Same-handle successors
  /// reuse its opaque so a vout that already copied the predecessor's value
  /// observes the new renderer target without reopening.
  func claimDirectPiPVideoCallbacks(_ registration: DirectPiPVideoCallbackRegistration) {
    let previous = directPiPVideoCallbackRegistration
    let previousGeneration = directPiPVideoCallbackGeneration

    directPiPVideoCallbackGeneration &+= 1
    let generation = directPiPVideoCallbackGeneration
    let slot: DirectPiPVideoCallbackSlot
    if let existing = directPiPVideoCallbackSlot {
      precondition(existing.lifetime === nativeHandleLifetime && !existing.isRetired)
      slot = existing
    } else {
      slot = registration.makeSlot(on: nativeHandleLifetime)
      directPiPVideoCallbackSlot = slot
    }
    registration.bind(to: slot, generation: generation)
    directPiPVideoCallbackRegistration = registration

    if let previous, previous !== registration {
      previous.unbind(generation: previousGeneration)
    }
  }

  /// Creates a fresh slot for a replacement native handle before retiring
  /// the prior handle's slot. Different handles never share an opaque.
  func moveDirectPiPVideoCallbacks(to lifetime: NativePlayerHandleLifetime) {
    let previousSlot = directPiPVideoCallbackSlot
    if let previousSlot {
      precondition(previousSlot.lifetime === nativeHandleLifetime)
      precondition(previousSlot.lifetime !== lifetime)
    }
    guard let registration = directPiPVideoCallbackRegistration else {
      directPiPVideoCallbackSlot = nil
      previousSlot?.retire()
      return
    }

    directPiPVideoCallbackGeneration &+= 1
    let generation = directPiPVideoCallbackGeneration
    let successorSlot = registration.makeSlot(on: lifetime)
    registration.bind(to: successorSlot, generation: generation)
    directPiPVideoCallbackSlot = successorSlot
    previousSlot?.retire()
  }

  /// Relinquishes the display target only if the caller still owns the current
  /// handle and generation. Native callback variables are cleared, while the
  /// dormant per-handle slot remains reusable by a sequential successor whose
  /// already-open vout still holds its opaque.
  func relinquishDirectPiPVideoCallbacks(_ registration: DirectPiPVideoCallbackRegistration) {
    let generation = registration.currentGeneration
    let ownsCurrentRegistration = directPiPVideoCallbackRegistration === registration
      && generation == directPiPVideoCallbackGeneration
      && registration.currentSlot === directPiPVideoCallbackSlot
      && registration.currentLifetime === nativeHandleLifetime

    if ownsCurrentRegistration {
      directPiPVideoCallbackRegistration = nil
      directPiPVideoCallbackGeneration &+= 1
      directPiPVideoCallbackSlot?.deactivate()
    }

    if let generation {
      registration.unbind(generation: generation)
    }
  }

  /// Permanently retires the current handle's slot during native replacement
  /// or final teardown. This differs from controller relinquishment: no later
  /// owner may reuse an opaque belonging to the outgoing handle.
  func retireDirectPiPVideoCallbacksForHandleEnd() {
    let registration = directPiPVideoCallbackRegistration
    let generation = registration?.currentGeneration
    let slot = directPiPVideoCallbackSlot
    if let slot {
      precondition(slot.lifetime === nativeHandleLifetime)
    }

    directPiPVideoCallbackRegistration = nil
    directPiPVideoCallbackSlot = nil
    if registration != nil || slot != nil {
      directPiPVideoCallbackGeneration &+= 1
    }
    if let registration, let generation {
      registration.unbind(generation: generation)
    }
    slot?.retire()
  }
}
#endif
