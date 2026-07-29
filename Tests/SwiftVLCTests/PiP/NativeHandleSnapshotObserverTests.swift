#if os(iOS) || os(macOS)
@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// Records what the player asks of an observer, and what the player's handle
/// was at the moment it asked.
@MainActor
private final class RecordingSnapshotObserver: NativeHandleSnapshotObserver {
  private(set) var refreshedHandles: [OpaquePointer] = []
  private(set) var invalidateCount = 0
  /// Weak, mirroring the real observers: a strong reference here would keep
  /// the player alive and hide the very deinit path under test.
  weak var player: Player?

  init(player: Player) {
    self.player = player
  }

  func refreshNativeHandleSnapshot() {
    if let pointer = player?.pointer {
      refreshedHandles.append(pointer)
    }
  }

  func invalidateNativeHandleSnapshot() {
    invalidateCount += 1
  }
}

extension Integration {
  /// A cached native handle is a second owner of a lifetime it does not
  /// control. `Player` replaces its handle independently of its own identity
  /// and releases the outgoing one, so every consumer holding a copy has to be
  /// moved onto the successor *before* the predecessor is freed.
  ///
  /// Missing that is what produced #86: PiP kept answering AVKit's synchronous
  /// queries from a snapshot taken before a replacement, and
  /// `libvlc_media_player_get_length` was eventually handed a freed handle.
  /// On device it surfaced as a `SIGBUS` inside `vlc_mutex_lock`, several
  /// frames away from the actual defect.
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct NativeHandleSnapshotObserverTests {
    // MARK: - The real PiP path

    /// The #86 regression. Replacement installs the successor and then releases
    /// the predecessor; a PiP controller left pointing at the predecessor is
    /// holding freed memory the moment that release lands.
    @Test
    func `A handle replacement moves the PiP snapshot onto the successor`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)

      let outgoing = player.pointer
      #expect(controller.callbackSnapshot.withLock { $0.playerPointer } == outgoing)

      try player.replaceNativePlayerForDrawablePlayback(target: nil)
      let incoming = player.pointer

      // The successor is allocated before the predecessor is released, so the
      // two addresses can never alias and this comparison is exact.
      #expect(incoming != outgoing, "the replacement did not install a new handle")
      #expect(
        controller.callbackSnapshot.withLock { $0.playerPointer } == incoming,
        "the PiP snapshot still points at the released handle"
      )

      await player.shutdown()
    }

    /// Shutdown is the other replacement: it swaps in an inert handle and tears
    /// the live one down off the main actor. Same hazard, different entry
    /// point.
    @Test
    func `Shutdown moves the PiP snapshot off the retiring handle`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let retiring = player.pointer

      await player.shutdown()

      #expect(
        controller.callbackSnapshot.withLock { $0.playerPointer } != retiring,
        "the PiP snapshot still points at the handle shutdown released"
      )
    }

    /// Invalidation clears rather than re-derives. `PiPController` holds its
    /// player strongly, so it always tears down before that player's `deinit`
    /// and never reaches this through the registry today — but the conformance
    /// is what the registry dispatches, and "clear" is the only answer that
    /// stays correct once there is no successor handle to point at.
    @Test
    func `An invalidated PiP controller clears its cached handle`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      #expect(controller.callbackSnapshot.withLock { $0.playerPointer } != nil)

      player.invalidateNativeHandleSnapshots()

      #expect(controller.callbackSnapshot.withLock { $0.playerPointer } == nil)
      await player.shutdown()
    }

    // MARK: - Ordering

    /// The refresh has to land while the outgoing handle is still alive.
    /// Republishing after the release would still leave the correct pointer
    /// cached at the end, so an end-state assertion alone cannot tell a fix
    /// from a race. Observing the handle *at callback time* can.
    @Test
    func `The successor is published before the predecessor is released`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let observer = RecordingSnapshotObserver(player: player)
      player.registerNativeHandleSnapshotObserver(observer)

      let outgoing = player.pointer
      try player.replaceNativePlayerForDrawablePlayback(target: nil)
      let incoming = player.pointer

      #expect(incoming != outgoing)
      #expect(
        observer.refreshedHandles.contains(incoming),
        "no refresh carried the successor handle"
      )
      #expect(
        observer.refreshedHandles.allSatisfy { $0 != outgoing },
        "a refresh published the handle that was about to be released"
      )
    }

    // MARK: - Registry semantics

    /// `deinit` has no successor to move to, so the only cached handle that
    /// stays valid is none. Distinguished from replacement deliberately:
    /// re-deriving a snapshot from a player that is mid-destruction is not a
    /// safe thing to ask for.
    @Test
    func `Player deinit invalidates rather than refreshes`() async {
      let observer: RecordingSnapshotObserver
      let refreshesBeforeDeinit: Int
      // Scoped so the player's last strong reference is gone at the closing
      // brace. `isolated deinit` then runs synchronously here on the main
      // actor, which is what makes the assertions below deterministic.
      do {
        let player = Player(instance: TestInstance.makeAudioOnly())
        observer = RecordingSnapshotObserver(player: player)
        player.registerNativeHandleSnapshotObserver(observer)
        await player.shutdown()
        refreshesBeforeDeinit = observer.refreshedHandles.count
      }

      #expect(observer.invalidateCount == 1, "deinit did not invalidate the cached handle")
      #expect(
        observer.refreshedHandles.count == refreshesBeforeDeinit,
        "deinit re-derived a snapshot from a player being destroyed"
      )
    }

    /// Registering twice must not double-notify. The PiP backends attach on
    /// several paths and a duplicate entry would be invisible until it showed
    /// up as a doubled generation bump.
    @Test
    func `Registering twice notifies once`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let observer = RecordingSnapshotObserver(player: player)
      player.registerNativeHandleSnapshotObserver(observer)
      player.registerNativeHandleSnapshotObserver(observer)

      try player.replaceNativePlayerForDrawablePlayback(target: nil)

      #expect(observer.refreshedHandles.count == 1)
      await player.shutdown()
    }

    @Test
    func `An unregistered observer stops being refreshed`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let observer = RecordingSnapshotObserver(player: player)
      player.registerNativeHandleSnapshotObserver(observer)
      player.unregisterNativeHandleSnapshotObserver(observer)

      try player.replaceNativePlayerForDrawablePlayback(target: nil)

      #expect(observer.refreshedHandles.isEmpty)
      await player.shutdown()
    }

    /// Held weakly. The observers are view-layer controllers, and a strong
    /// reference from the player would keep a dismissed screen's controller
    /// alive past its own teardown — which is the situation that produced the
    /// dangling pointer to begin with.
    @Test
    func `A released observer is dropped rather than kept alive`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weak var probe: RecordingSnapshotObserver?
      do {
        let observer = RecordingSnapshotObserver(player: player)
        probe = observer
        player.registerNativeHandleSnapshotObserver(observer)
      }

      #expect(probe == nil, "the player kept the observer alive")

      // The dead entry must not be dereferenced or left behind.
      try player.replaceNativePlayerForDrawablePlayback(target: nil)
      #expect(player.nativeHandleSnapshotObservers.isEmpty)

      await player.shutdown()
    }

    #if os(iOS)

    // MARK: - The path the device crash came through

    /// `IOSNativePiPMediaController` is what libVLC's own PiP module calls, and
    /// `mediaLength()` reaches straight into `libvlc_media_player_get_length`
    /// with whatever handle the snapshot holds. This is the exact query that
    /// faulted in #86.
    @Test
    func `A handle replacement moves the native media controller snapshot`() async throws {
      let player = Player(instance: TestInstance.shared)
      let mediaController = IOSNativePiPMediaController()
      mediaController.player = player

      let outgoing = player.pointer
      #expect(mediaController.callbackSnapshot.withLock { $0.playerPointer } == outgoing)

      try player.replaceNativePlayerForDrawablePlayback(target: nil)
      let incoming = player.pointer

      #expect(incoming != outgoing, "the replacement did not install a new handle")
      #expect(
        mediaController.callbackSnapshot.withLock { $0.playerPointer } == incoming,
        "mediaLength() would interrogate the handle the replacement released"
      )

      await player.shutdown()
    }

    /// Detaching has to unhook the registration too, or a controller the view
    /// layer has finished with keeps being refreshed by a player it no longer
    /// represents.
    @Test
    func `Detaching the native media controller unhooks it from the player`() async {
      let player = Player(instance: TestInstance.shared)
      let mediaController = IOSNativePiPMediaController()
      mediaController.player = player
      #expect(player.nativeHandleSnapshotObservers.count == 1)

      mediaController.player = nil

      #expect(player.nativeHandleSnapshotObservers.isEmpty)
      #expect(mediaController.callbackSnapshot.withLock { $0.playerPointer } == nil)

      await player.shutdown()
    }
    #endif
  }
}
#endif
