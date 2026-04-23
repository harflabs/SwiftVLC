@testable import SwiftVLC
import Synchronization
import Testing

/// Hammers the create/destroy lifecycle of every SwiftVLC type that
/// offloads blocking libVLC teardown to `DispatchQueue.global`. Catches
/// regressions in the async-deinit plumbing: use-after-free on the
/// retained callback box, double-release, leaked `VLCInstance`
/// references, or a deadlock if cleanup ordering drifts.
///
/// Serial (`--no-parallel` in CI). Each test asserts *on its own
/// thread* that construction and destruction complete without
/// crashing — the offloaded cleanup runs on the utility queue
/// independently, so the test body deliberately doesn't wait for it.
/// If the offload ever had a bug that the current thread could observe
/// (e.g. use-after-free via a retained pointer), the loop body — not a
/// post-loop sleep — is where it would surface.
extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct LifecycleStressTests {
    // MARK: - Player

    @Test
    func `Rapid Player create destroy does not crash`() {
      for _ in 0..<50 {
        let player = Player(instance: TestInstance.shared)
        _ = player.state
      }
    }

    @Test
    func `Player create with active stream then drop`() {
      // Exercises the path where the event consumer Task is still live
      // when deinit fires — Player.deinit cancels `eventTask`, then
      // offloads bridge invalidation + C-object release.
      for _ in 0..<30 {
        let player = Player(instance: TestInstance.shared)
        let stream = player.events
        let task = Task.detached { @Sendable in
          for await _ in stream {}
        }
        task.cancel()
      }
    }

    @Test
    func `Player deinit during active playback does not crash`() throws {
      // Start and immediately drop — the deinit races against libVLC's
      // demuxer + decoder spinning up. The offload means the blocking
      // `libvlc_media_player_stop_async` / release runs on a background
      // queue; nothing on the test thread should fault.
      //
      // Kept small (3 players) because each blocking teardown pins a
      // utility-queue worker for up to a second.
      for _ in 0..<3 {
        let player = Player(instance: TestInstance.shared)
        try player.play(Media(url: TestMedia.twosecURL))
      }
    }

    // MARK: - DialogHandler

    @Test
    func `Rapid DialogHandler create destroy`() {
      // DialogHandler.deinit offloads `libvlc_dialog_set_callbacks(nil,
      // nil)` off the calling thread while strong-capturing the
      // `VLCInstance`. 100 iterations stress the cleanup ordering:
      // clear callbacks → finish stream → release retained box.
      for _ in 0..<100 {
        let handler = DialogHandler(instance: TestInstance.shared)
        _ = handler.dialogs
      }
    }

    /// Captures the stream, drops the handler, then asserts the stream
    /// finishes deterministically via `continuation.finish()` in the
    /// offloaded deinit. The enclosing `withTaskGroup` races the drain
    /// against a 2-second ceiling; on success the drain wins and we
    /// return immediately, on regression the ceiling wins and the
    /// `#expect` fails with a clear message.
    @Test
    func `DialogHandler stream finishes after handler deinit`() async {
      let stream: AsyncStream<DialogEvent>
      do {
        let handler = DialogHandler(instance: TestInstance.shared)
        stream = handler.dialogs
      } // handler dropped — offloaded deinit must eventually finish the stream

      let drained = Mutex(false)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { @Sendable in
          for await _ in stream {}
          drained.withLock { $0 = true }
        }
        group.addTask { @Sendable in
          try? await Task.sleep(for: .seconds(2))
        }
        await group.next()
        group.cancelAll()
      }
      #expect(drained.withLock { $0 }, "stream did not finish within 2s after DialogHandler deinit")
    }

    // MARK: - RendererDiscoverer

    @Test
    func `Rapid RendererDiscoverer create destroy`() throws {
      // Each discoverer attaches two event callbacks and spins a
      // discovery thread. The offloaded deinit must detach both, finish
      // the continuation, release the box, and release the discoverer —
      // in that order.
      guard let service = RendererDiscoverer.availableServices(instance: TestInstance.shared).first else {
        return // No services on this platform — the test is a no-op.
      }
      for _ in 0..<30 {
        let d = try RendererDiscoverer(name: service.name, instance: TestInstance.shared)
        _ = d.events
      }
    }

    @Test
    func `RendererDiscoverer started then dropped`() throws {
      guard let service = RendererDiscoverer.availableServices(instance: TestInstance.shared).first else {
        return
      }
      // Start discovery before dropping so deinit has to stop an actively
      // running thread.
      for _ in 0..<10 {
        let d = try RendererDiscoverer(name: service.name, instance: TestInstance.shared)
        try d.start()
      }
    }

    // MARK: - MediaDiscoverer

    @Test
    func `Rapid MediaDiscoverer create destroy`() throws {
      guard let service = MediaDiscoverer.availableServices(category: .lan, instance: TestInstance.shared).first else {
        return
      }
      for _ in 0..<30 {
        _ = try MediaDiscoverer(name: service.name, instance: TestInstance.shared)
      }
    }

    // MARK: - Mixed

    @Test
    func `Mixed lifecycle across types`() {
      // All offload paths churning together — exercises the shared
      // utility queue with concurrent cleanup work.
      for _ in 0..<30 {
        let p = Player(instance: TestInstance.shared)
        _ = p.events
        let h = DialogHandler(instance: TestInstance.shared)
        _ = h.dialogs
      }
    }

    // MARK: - Media / MediaList

    @Test
    func `Rapid Media create and drop`() throws {
      // Media's deinit is a synchronous `libvlc_media_release` — no
      // offload needed. Test still guards against a regression if we
      // ever change that.
      for _ in 0..<200 {
        _ = try Media(url: TestMedia.testMP4URL)
      }
    }

    @Test
    func `Rapid MediaList mutate`() throws {
      let list = MediaList()
      for _ in 0..<100 {
        let media = try Media(url: TestMedia.testMP4URL)
        try list.append(media)
      }
      #expect(list.count == 100)
      for _ in 0..<50 {
        try list.remove(at: 0)
      }
      #expect(list.count == 50)
    }
  }
}
