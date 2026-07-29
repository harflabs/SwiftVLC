#if os(iOS) || os(macOS)

/// A consumer that caches the player's native handle so callback threads can
/// read it without touching the main actor.
///
/// AVKit and VLC's own PiP module ask synchronous questions from arbitrary
/// threads, so the handle they interrogate is published into a lock rather
/// than read through the main-actor `Player`. That makes the cached copy a
/// *second* owner of a lifetime it does not control: ``Player`` replaces its
/// native handle independently of its own identity — lazily when
/// drawable-hosted playback stops, and on a renderer recast — and releases the
/// outgoing one.
///
/// Nothing in the type system connects those two facts, which is how a freed
/// handle survived in two separate snapshots. Conforming here is what makes
/// the connection explicit: an observer is told to republish *after* the new
/// handle is installed and *before* the old one is released, so no callback
/// thread can ever observe a pointer that has been freed.
/// The three transitions below mirror the direct-PiP callback hooks
/// (`moveDirectPiPVideoCallbacks(to:)` / `retireDirectPiPVideoCallbacksForHandleEnd()`)
/// one for one. Those cover the vout callback slot; these cover the cached
/// handle the synchronous AVKit queries read. Any new handle transition needs
/// an entry in both sets.
@MainActor
protocol NativeHandleSnapshotObserver: AnyObject {
  /// Republish the cached handle from the player's current one.
  func refreshNativeHandleSnapshot()

  /// Publish "no handle": the player's native handle is ending with no
  /// successor to move to, so the only safe cached value is none.
  func invalidateNativeHandleSnapshot()
}

extension Player {
  /// Registers a consumer to be refreshed on every native-handle replacement.
  ///
  /// Held weakly: observers are PiP controllers and media controllers whose
  /// lifetime is owned by the view layer, and a strong reference here would
  /// keep a dismissed screen's controller alive past its teardown — the exact
  /// situation that produced the dangling pointer in the first place.
  func registerNativeHandleSnapshotObserver(_ observer: NativeHandleSnapshotObserver) {
    pruneNativeHandleSnapshotObservers()
    guard !nativeHandleSnapshotObservers.contains(where: { $0.value === observer }) else {
      return
    }
    nativeHandleSnapshotObservers.append(WeakNativeHandleSnapshotObserver(observer))
  }

  func unregisterNativeHandleSnapshotObserver(_ observer: NativeHandleSnapshotObserver) {
    nativeHandleSnapshotObservers.removeAll { $0.value == nil || $0.value === observer }
  }

  /// Tells every live observer to republish.
  ///
  /// Call sites must invoke this *between* installing the successor handle and
  /// releasing the predecessor. Refreshing earlier republishes the handle that
  /// is about to be freed; refreshing later leaves a window in which a
  /// callback thread reads freed memory.
  func refreshNativeHandleSnapshots() {
    pruneNativeHandleSnapshotObservers()
    for box in nativeHandleSnapshotObservers {
      box.value?.refreshNativeHandleSnapshot()
    }
  }

  /// Tells every live observer that the handle is ending with no successor.
  ///
  /// Used by `deinit`, where there is nothing to republish: the player itself
  /// is going away, so an observer that re-derived its cache from `self` would
  /// be reading a half-destroyed object.
  func invalidateNativeHandleSnapshots() {
    pruneNativeHandleSnapshotObservers()
    for box in nativeHandleSnapshotObservers {
      box.value?.invalidateNativeHandleSnapshot()
    }
    nativeHandleSnapshotObservers.removeAll()
  }

  private func pruneNativeHandleSnapshotObservers() {
    nativeHandleSnapshotObservers.removeAll { $0.value == nil }
  }
}

/// Weak box. `NativeHandleSnapshotObserver` is a class-bound protocol, so this
/// only needs to exist because Swift arrays cannot hold weak elements
/// directly.
struct WeakNativeHandleSnapshotObserver {
  weak var value: (any NativeHandleSnapshotObserver)?

  init(_ value: any NativeHandleSnapshotObserver) {
    self.value = value
  }
}

#endif
