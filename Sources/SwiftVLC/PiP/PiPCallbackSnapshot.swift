#if os(iOS) || os(macOS)

import CoreMedia
import Synchronization

/// The state AVKit's synchronous queries need, readable from any thread.
///
/// AVKit asks for a playback range and a paused flag from arbitrary threads
/// and expects an answer immediately. Answering by blocking on the main actor
/// closes a deadlock cycle — the main thread is frequently waiting on libVLC
/// or video-output teardown, which can in turn be gated behind the callback
/// thread. Publishing the few values those queries need into a lock the main
/// actor updates lets the callback thread answer without ever waiting on
/// main.
///
/// The lock is only ever held across plain field reads and writes. It never
/// calls libVLC, never touches the main actor, and never runs caller-supplied
/// code, so it cannot participate in a lock-ordering cycle of its own.
struct PiPCallbackSnapshot: @unchecked Sendable {
  /// The native handle the queries should interrogate, or `nil` while no
  /// player is attached. Carried here rather than read through the owner so
  /// the callback thread never touches main-actor state.
  var playerPointer: OpaquePointer?
  /// PiP's control timebase, used to place the current time inside the
  /// reported range.
  var controlTimebase: CMTimebase?
  /// Whether PiP should render as playing. Mirrors
  /// ``PiPController/pipPlaybackActive``.
  var isPlaybackActive = false
  /// Bumped whenever the attached player handle changes.
  ///
  /// A query reads the whole snapshot under one lock acquisition, so the
  /// pointer and timebase it works with always belong to the same generation.
  /// The generation is what makes that guarantee checkable rather than
  /// incidental.
  var generation: UInt64 = 0

  /// `true` once a handle has been published, so a query can distinguish
  /// "not attached yet" from "attached to a player that reports nothing".
  var isAttached: Bool {
    playerPointer != nil
  }
}

extension PiPController {
  /// Republishes everything the callback threads read.
  ///
  /// Called from the main actor whenever the attached handle, the timebase or
  /// the playback flag changes. Cheap enough to call unconditionally: it is a
  /// handful of field writes under an uncontended lock.
  func refreshCallbackSnapshot() {
    let pointer: OpaquePointer? = player.pointer
    let timebase = controlTimebase
    let active = pipPlaybackActive

    callbackSnapshot.withLock { snapshot in
      if snapshot.playerPointer != pointer {
        snapshot.generation &+= 1
      }
      snapshot.playerPointer = pointer
      snapshot.controlTimebase = timebase
      snapshot.isPlaybackActive = active
    }
  }

  /// Clears the snapshot so in-flight callbacks stop interrogating a handle
  /// that is being torn down.
  func invalidateCallbackSnapshot() {
    callbackSnapshot.withLock { snapshot in
      snapshot.playerPointer = nil
      snapshot.controlTimebase = nil
      snapshot.isPlaybackActive = false
      snapshot.generation &+= 1
    }
  }
}

#endif
