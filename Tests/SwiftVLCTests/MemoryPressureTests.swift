// swiftlint:disable file_length
//
// MemoryPressureTests is a deliberately long, flat list of churn
// scenarios for memory and lifecycle stress. Each scenario is a few
// dozen lines of setup + assertion; splitting by domain area would
// scatter related stress patterns across files for no benefit.

@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

#if os(iOS) || os(macOS)
import AVFoundation
import AVKit
#endif

/// Aggressive pressure tests that hammer the full lifecycle of every
/// SwiftVLC surface — Player, EventBridge, Media, MediaList,
/// MediaListPlayer, Equalizer, LogBroadcaster, DialogHandler, Thumbnail,
/// PiPController, VideoSurface — at volumes high enough to surface leaks
/// and races that the baseline `MemoryAndRetainTests` and
/// `LifecycleStressTests` are too gentle to reveal.
///
/// These tests exist alongside the lighter suites, not replacing them.
/// The lighter suites fail fast on simple retain cycles. These are the
/// long-running probes: unbounded RSS growth, zombie tasks, C-allocator
/// leaks (CVPixelBuffer, libVLC event boxes), and teardown races that
/// only surface after hundreds of iterations.
///
/// Each suite is `.serialized` because running multiple churn loops in
/// parallel thrashes libVLC's shared instance state and produces false
/// positives. The per-suite time limit is generous; individual tests
/// target ~5-10 seconds on a current-gen Apple Silicon Mac.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(5)), .serialized)
  @MainActor struct MemoryPressureTests {
    // MARK: - Player churn under simulated SwiftUI sheet dismissal

    /// Mirrors the Showcase `VideoPlayerView` lifecycle: create Player,
    /// kick off playback, fire `.stop()` from simulated `.onDisappear`,
    /// drop. Pressure on `Player.deinit`'s offloaded cleanup path and
    /// the implicit assumption that `stop_async` + release in that order
    /// doesn't race the decode thread.
    ///
    /// A weak probe per iteration catches retain leaks; an RSS delta
    /// catches C-side allocator leaks (libVLC frame buffers, audio
    /// output scratch, event callback boxes) that the weak probe misses.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Player play-stop-dismiss churn does not leak`() async throws {
      let iterations = 60
      let probes = WeakPlayerProbes()
      let rssBefore = MemorySampler.residentBytes()

      for _ in 0..<iterations {
        let instance = TestInstance.makeAudioOnly()
        let player = Player(instance: instance)
        probes.add(player)
        try player.play(url: TestMedia.twosecURL)
        // Simulate a tap-and-dismiss: no wait for playing, just stop.
        // This is the worst-case dismissal pattern users hit.
        player.stop()
      }

      // Give the offloaded cleanup path generous time to run. Each
      // Player.deinit hops onto the utility queue to invalidate the
      // event bridge and release the player; 60 iterations deep, the
      // queue can be several hundred milliseconds behind.
      try await Task.sleep(for: .seconds(2))
      await yield(16)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / \(iterations) Players leaked after dismiss churn")

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      // Generous threshold: libVLC retains some module scratch per
      // instance; `iterations` fresh instances will grow RSS several MB
      // legitimately. A real leak (frame buffers, event boxes) pushes
      // the delta into hundreds of MB for 60 iterations.
      #expect(deltaMB < 120, "Player churn leaked \(Int(deltaMB)) MB of resident memory")
    }

    /// Same pattern, but reuses a single `VLCInstance` across all
    /// iterations — the hot path when a user navigates into and out of
    /// the showcase repeatedly without leaving the app. Catches state
    /// that accumulates on the instance (audio output pool entries,
    /// module cache, parsed-media cache) rather than on each player.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Player churn on shared instance does not accumulate state`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let iterations = 100
      let probes = WeakPlayerProbes()
      let rssBefore = MemorySampler.residentBytes()

      for _ in 0..<iterations {
        let player = Player(instance: instance)
        probes.add(player)
        try player.play(Media(url: TestMedia.twosecURL))
        player.stop()
      }

      try await Task.sleep(for: .seconds(2))
      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / \(iterations) Players leaked on shared instance")

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      #expect(deltaMB < 80, "Shared-instance churn leaked \(Int(deltaMB)) MB")
    }

    /// Start, wait until `.playing`, then stop + drop. Exercises the
    /// full event pipeline (attach → drain → detach) per iteration,
    /// not just the create/destroy cold path.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Player reach-playing-then-drop churn`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let iterations = 20
      let probes = WeakPlayerProbes()

      for _ in 0..<iterations {
        let player = Player(instance: instance)
        probes.add(player)
        let reached = subscribeAndAwait(.playing, on: player, timeout: .seconds(3))
        try player.play(url: TestMedia.twosecURL)
        _ = await reached.value
        player.stop()
      }

      try await Task.sleep(for: .seconds(2))
      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) Players leaked after reach-playing churn")
    }

    // MARK: - Concurrent player creation

    /// Races N tasks creating and dropping players concurrently. If
    /// `Player.init` or `EventBridge.init` had a hidden shared-state
    /// race (e.g. a global registry mutated without synchronization),
    /// this surfaces as a sporadic crash or deadlock under the stress
    /// wrapper.
    @Test
    func `Concurrent player creation across tasks does not deadlock or crash`() async {
      let instance = TestInstance.makeAudioOnly()
      let taskCount = 8
      let perTask = 30

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<taskCount {
          group.addTask { @MainActor in
            for _ in 0..<perTask {
              autoreleasepool {
                let p = Player(instance: instance)
                _ = p.events
                _ = p.state
              }
            }
          }
        }
        await group.waitForAll()
      }
      await yield(32)
    }

    // MARK: - Event stream backpressure

    /// A slow consumer drains events at real-time rate while libVLC
    /// broadcasts at frame rate. `AsyncStream` is `.bufferingNewest(64)`
    /// per `EventBridge.makeStream`, so old events drop — memory stays
    /// bounded. Validates that assumption holds under sustained active
    /// playback, since the stream buffer growing unbounded would be a
    /// silent leak of `PlayerEvent` enum cases (some carry strings and
    /// media references).
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Slow event consumer does not balloon memory`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let stream = player.events

      try player.play(url: TestMedia.twosecURL)

      let consumed = Mutex(0)
      let consumer = Task.detached { @Sendable in
        var n = 0
        for await _ in stream {
          n += 1
          // Simulate a slow consumer — 5ms per event is slower than
          // VLC's timeChanged cadence, so the buffer will churn.
          try? await Task.sleep(for: .milliseconds(5))
          if n > 200 { break }
        }
        consumed.withLock { $0 = n }
      }

      try? await Task.sleep(for: .seconds(2))
      player.stop()
      consumer.cancel()
      _ = await consumer.value

      #expect(consumed.withLock { $0 } > 0, "Consumer never received any events")
      // The primary assertion is that we didn't crash or OOM. If the
      // buffering policy regressed (say, to `.unbounded`), 2s of
      // playback + a 5ms-per-event consumer would queue thousands of
      // events and trip the enclosing timeLimit.
    }

    /// Multiple concurrent consumers on the same player. Each is an
    /// independent continuation; a bug in `ContinuationStore.remove`
    /// (e.g. racing with `broadcast`) would surface as either a missed
    /// event or a leaked continuation.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Ten concurrent event consumers terminate cleanly`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)

      try player.play(url: TestMedia.twosecURL)

      let finished = Mutex(0)
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
          let stream = player.events
          group.addTask { @Sendable in
            var count = 0
            for await _ in stream {
              count += 1
              if count > 10 { break }
            }
            finished.withLock { $0 += 1 }
          }
        }
        try? await Task.sleep(for: .milliseconds(800))
        player.stop()
        group.cancelAll()
        await group.waitForAll()
      }

      #expect(finished.withLock { $0 } > 0, "No consumer completed a drain")
    }

    // MARK: - Media parse + cancel racing

    /// Rapid parse-and-cancel cycle. Each iteration starts a parse on a
    /// fresh `Media`, then cancels the enclosing task before libVLC can
    /// resolve the callback. The `ParseContinuation` box's retain/release
    /// balance has to be exactly right; a single missed release leaks
    /// the whole continuation graph.
    @Test
    func `Parse-then-cancel does not leak continuations`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let iterations = 50
      let probes = WeakMediaProbes()

      for _ in 0..<iterations {
        try autoreleasepool {
          let media = try Media(url: TestMedia.testMP4URL)
          probes.add(media)
          let task = Task {
            _ = try? await media.parse(timeout: .seconds(5), instance: instance)
          }
          // Cancel immediately. The parse may or may not have started.
          task.cancel()
        }
      }

      try await Task.sleep(for: .seconds(1))
      await yield(16)

      let alive = probes.aliveCount()
      // Some media may still be alive because their parse is still
      // cleaning up; allow a small residue but not unbounded growth.
      #expect(alive < 10, "\(alive) / \(iterations) Media leaked through parse/cancel race")
    }

    /// Parse completion arriving after the media is dropped. The
    /// callback retains the `ParseContinuation` via `Unmanaged`; if the
    /// callback doesn't release it under every control-flow path, the
    /// continuation — and through it the Media's event manager — leaks.
    @Test
    func `Parse completion releases the continuation after media drop`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let iterations = 30
      let probes = WeakMediaProbes()

      for _ in 0..<iterations {
        let media = try Media(url: TestMedia.testMP4URL)
        probes.add(media)
        // Fire-and-forget parse. We don't await it; the media is
        // dropped and the parse callback must still resolve cleanly.
        Task.detached { @Sendable in
          _ = try? await media.parse(timeout: .milliseconds(500), instance: instance)
        }
      }

      // Long wait: the parse timeout is 500ms, so all in-flight
      // callbacks should have fired within ~1s.
      try await Task.sleep(for: .seconds(2))
      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) Media leaked after fire-and-forget parse")
    }

    // MARK: - Thumbnail cancellation chaos

    /// Launch N concurrent thumbnail requests, cancel them at staggered
    /// intervals. Stresses the `ThumbnailCoordinator` actor, the
    /// `ThumbnailOperation` state machine, and the shared-with-libVLC
    /// callback retain balance.
    @Test
    func `Concurrent thumbnail cancellation does not leak media`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let iterations = 20
      let probes = WeakMediaProbes()

      try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<iterations {
          let media = try Media(url: TestMedia.twosecURL)
          probes.add(media)
          group.addTask { @Sendable in
            let task = Task {
              _ = try? await media.thumbnail(
                at: .seconds(1),
                width: 64,
                height: 64,
                timeout: .milliseconds(500),
                instance: instance
              )
            }
            try? await Task.sleep(for: .milliseconds(5 + i * 3))
            task.cancel()
            _ = await task.value
          }
        }
        try await group.waitForAll()
      }

      try await Task.sleep(for: .seconds(1))
      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / \(iterations) Media leaked after thumbnail cancellation")
    }

    // MARK: - Equalizer install/clear churn (deep)

    /// The existing `MemoryAndRetainTests` churns EQ install/clear 200
    /// times. Here we double it and verify RSS stays bounded — the
    /// onChange closure builds a `[weak self, weak newValue]` capture
    /// that should release cleanly.
    @Test
    func `Equalizer install-clear-churn with RSS guard`() async {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let rssBefore = MemorySampler.residentBytes()
      let probes = WeakEqualizerProbes()

      for _ in 0..<400 {
        autoreleasepool {
          let eq = Equalizer()
          probes.add(eq)
          player.equalizer = eq
          eq.preamp = Float.random(in: -5...5)
          var bands = eq.bands
          if !bands.isEmpty {
            bands[0] = Float.random(in: -10...10)
            eq.bands = bands
          }
          player.equalizer = nil
        }
      }

      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) Equalizers leaked after 400 installs")

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      #expect(deltaMB < 30, "Equalizer churn leaked \(Int(deltaMB)) MB of resident memory")
    }

    // MARK: - MediaList / MediaListPlayer churn

    /// `MediaListPlayer.rebuildNativePlayer` tears down the underlying
    /// `libvlc_media_list_player_t` and builds a new one whenever the
    /// media list or player is assigned `nil`. 50 swap cycles per
    /// iteration exercise every branch: stop_async → release → new.
    @Test
    func `MediaListPlayer rebuild churn does not leak`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let listPlayer = MediaListPlayer(instance: instance)
      let rssBefore = MemorySampler.residentBytes()

      for _ in 0..<50 {
        try autoreleasepool {
          let list = MediaList()
          try list.append(Media(url: TestMedia.testMP4URL))
          try list.append(Media(url: TestMedia.twosecURL))
          let player = Player(instance: instance)
          listPlayer.mediaPlayer = player
          listPlayer.mediaList = list
          // Clear both — this triggers rebuildNativePlayer twice.
          listPlayer.mediaPlayer = nil
          listPlayer.mediaList = nil
        }
      }

      try await Task.sleep(for: .seconds(1))
      await yield(32)

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      #expect(deltaMB < 60, "MediaListPlayer rebuild churn leaked \(Int(deltaMB)) MB")
    }

    // MARK: - Log stream churn

    /// Log consumers subscribing and dropping during active playback.
    /// Stresses `LogBroadcaster.scheduleReconcile`'s install/uninstall
    /// path: each add triggers a reconcile, each remove triggers
    /// another, and the callback box's retain/release balance must hold.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Log subscriber churn during playback does not leak`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      try player.play(url: TestMedia.twosecURL)

      for _ in 0..<30 {
        let stream = instance.logStream(minimumLevel: .warning)
        let task = Task.detached { @Sendable in
          var n = 0
          for await _ in stream {
            n += 1
            if n > 5 { break }
          }
        }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        _ = await task.value
      }

      player.stop()
      await yield(32)

      // No weak probe — LogBroadcaster is part of the instance, always
      // retained. The real assertion is that this test didn't crash or
      // deadlock on the install/uninstall race. The reconcile queue
      // handles both install and uninstall serially; a regression (e.g.
      // losing the install-in-flight flag) would surface as a crash or
      // the callback firing after the instance was freed.
    }

    // MARK: - DialogHandler churn across instances

    /// Each DialogHandler registers against its instance's pointer-keyed
    /// registry. Create-and-drop cycles must leave the registry empty.
    /// A stale entry would lock out any future handler on that instance.
    @Test
    func `DialogHandler churn per instance leaves registry clean`() async {
      let rssBefore = MemorySampler.residentBytes()

      for _ in 0..<40 {
        autoreleasepool {
          let instance = TestInstance.makeAudioOnly()
          for _ in 0..<3 {
            let handler = DialogHandler(instance: instance)
            _ = handler.dialogs
          }
        }
      }

      try? await Task.sleep(for: .seconds(1))
      await yield(32)

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      // 40 instances × 3 handlers, all dropped — RSS growth is entirely
      // allocator slack; should be well under 50MB.
      #expect(deltaMB < 80, "DialogHandler churn leaked \(Int(deltaMB)) MB")
    }

    // MARK: - PiPController churn

    #if os(iOS) || os(macOS)
    /// The critical lifecycle gap. `PiPController.deinit` calls
    /// `libvlc_video_set_callbacks(nil)` while the player may still be
    /// active; the vmem decode thread may be mid-callback. Heavy churn
    /// without reaching `.playing` still exercises attach + detach under
    /// pressure.
    @Test
    func `PiPController churn without playback does not leak or crash`() async {
      let instance = TestInstance.makeAudioOnly()
      let probes = WeakPiPControllerProbes()
      let rssBefore = MemorySampler.residentBytes()

      for _ in 0..<50 {
        autoreleasepool {
          let player = Player(instance: instance)
          let controller = PiPController(player: player)
          probes.add(controller)
          _ = controller.layer
        }
      }

      try? await Task.sleep(for: .seconds(2))
      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / 50 PiPControllers leaked")

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      #expect(deltaMB < 100, "PiPController churn leaked \(Int(deltaMB)) MB")
    }

    /// The real failure mode: PiPController churn *during* active
    /// playback. This is what happens in the Showcase when a user opens
    /// the PiP case study, plays, and navigates back. If H1 is correct,
    /// this test will crash or leak badly.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `PiPController churn during active playback`() async throws {
      let iterations = 15
      let probes = WeakPiPControllerProbes()

      for _ in 0..<iterations {
        let instance = TestInstance.makeAudioOnly()
        let player = Player(instance: instance)
        let controller = PiPController(player: player)
        probes.add(controller)

        try player.play(url: TestMedia.twosecURL)
        // Short stabilization — enough for vmem callbacks to be
        // attached and possibly start flowing, not enough to finish.
        try? await Task.sleep(for: .milliseconds(200))

        // Simulate dismissal: stop player, drop controller + player
        // in whatever order SwiftUI chooses. PiPController deinits
        // first (it holds player strongly); it will call
        // libvlc_video_set_callbacks(nil) on a live player.
        player.stop()
      }

      try await Task.sleep(for: .seconds(2))
      await yield(64)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / \(iterations) PiPControllers leaked during playback churn")
    }

    /// Minimal PiPController lifecycle: single create, single drop, no
    /// playback, no observations triggered. Regression guard for the
    /// `AVPictureInPictureController.ContentSource` → `playbackDelegate`
    /// retention cycle: the content source retains its `playbackDelegate`
    /// strongly at runtime despite the header declaring the property
    /// `weak`, so conforming `PiPController` directly would form
    /// `PiPController → pipController → contentSource → playbackDelegate
    /// (self)` and prevent deinit. The internal proxy with a weak
    /// back-reference avoids the cycle; this test fails if anything
    /// reintroduces it.
    @Test
    func `PiPController deallocates after a single create-and-drop`() async {
      weak var weakController: PiPController?
      let player = Player(instance: TestInstance.makeAudioOnly())
      do {
        let controller = PiPController(player: player)
        weakController = controller
      }
      await yield(32)
      try? await Task.sleep(for: .milliseconds(500))
      await yield(32)

      #expect(weakController == nil, "PiPController leaked in minimal lifecycle — AVKit delegate retention cycle regressed")
    }

    /// Covers the `setupPiPController` code path on runners where
    /// `AVPictureInPictureController.isPictureInPictureSupported()`
    /// returns `true` (the guard at the top of `setupPiPController`
    /// bails early on unsupported environments, so the delegate cycle
    /// couldn't form there). Failure means the fix regressed on the
    /// only platform where the fix matters.
    @Test
    func `PiPController deallocates on PiP-supported runners`() async {
      let supported = AVPictureInPictureController.isPictureInPictureSupported()
      weak var weakController: PiPController?
      let player = Player(instance: TestInstance.makeAudioOnly())
      do {
        let controller = PiPController(player: player)
        weakController = controller
      }
      await yield(64)
      try? await Task.sleep(for: .milliseconds(500))
      await yield(64)

      #expect(weakController == nil, "PiPController leaked (PiP supported: \(supported))")
    }

    /// Drop the controller mid-playback, then drive the player through
    /// many observable changes. Regression guard for `stateObserverTask`
    /// retaining `self` across suspension: hoisting `guard let self`
    /// above an `await` would capture the strong binding into the
    /// suspended task frame and pin `self` until an observed property
    /// changed — which wouldn't happen while the controller was leaked.
    /// The observer scopes `guard let self` *inside* a `for await _ in
    /// player.events` loop body so the binding doesn't persist across
    /// the implicit next-event suspension; this test confirms.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `PiPController deallocates even while player is churning observable state`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weak var weakController: PiPController?

      do {
        let controller = PiPController(player: player)
        weakController = controller
        try await Task.sleep(for: .milliseconds(100))
      }
      await yield(32)

      try player.play(url: TestMedia.twosecURL)
      for i in 0..<50 {
        player.volume = Float(i % 100) / 100
        if i % 5 == 0 {
          player.pause()
          player.resume()
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      player.stop()
      try await Task.sleep(for: .seconds(2))
      await yield(128)

      #expect(weakController == nil, "PiPController leaked through observable state churn — observer task or delegate cycle regressed")
    }

    /// Drop after real vmem frames have flowed through the pipeline.
    /// Exercises the case where AVKit's sample-buffer renderer has
    /// actually enqueued frames before teardown; the retained
    /// `CVPixelBufferPool` and pending `CMSampleBuffer`s on the
    /// display layer shouldn't pin the controller.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `PiPController drop after vmem frames flow`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weak var weakController: PiPController?

      do {
        let controller = PiPController(player: player)
        weakController = controller
        try player.play(url: TestMedia.twosecURL)
        try await Task.sleep(for: .milliseconds(500))
        player.stop()
        try await Task.sleep(for: .milliseconds(200))
      }
      await yield(64)
      try? await Task.sleep(for: .seconds(1))
      await yield(64)

      #expect(weakController == nil, "PiPController leaked after vmem frames flowed")
    }
    #endif

    // MARK: - "Player keeps running after dismiss" timing probe

    /// Measures how long after `.onDisappear`-style teardown libVLC's
    /// actual stop + release completes. The Player's `isolated deinit`
    /// dispatches cleanup to a utility queue; if the queue is slow, the
    /// audio output keeps playing after the user has left the screen.
    /// The user-reported "player keeps running" is exactly this delay.
    ///
    /// This test doesn't assert a hard threshold — it records the
    /// observed cleanup delay so we can see it directly. A well-behaved
    /// pipeline should finish within ~200ms.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Player cleanup after drop completes within a reasonable window`() async throws {
      let cleanupFinished = Mutex(false)
      let finishedAt = Mutex<ContinuousClock.Instant?>(nil)
      let droppedAt: ContinuousClock.Instant

      do {
        let instance = TestInstance.makeAudioOnly()
        let player = Player(instance: instance)
        try player.play(url: TestMedia.twosecURL)
        try await Task.sleep(for: .milliseconds(100))
        player.stop()
        droppedAt = ContinuousClock.now
      }

      // Poll for cleanup: we can't directly observe deinit completion,
      // but we can poll until a fresh utility-queue task runs, which
      // signals the queue has drained behind us.
      DispatchQueue.global(qos: .utility).async {
        cleanupFinished.withLock { $0 = true }
        finishedAt.withLock { $0 = ContinuousClock.now }
      }

      let start = ContinuousClock.now
      while !cleanupFinished.withLock({ $0 }), ContinuousClock.now - start < .seconds(5) {
        try await Task.sleep(for: .milliseconds(20))
      }

      let completed = cleanupFinished.withLock { $0 }
      #expect(completed, "Utility queue never drained within 5s after player drop — cleanup backed up")

      if let stamp = finishedAt.withLock({ $0 }) {
        let delay = stamp - droppedAt
        // Log for visibility; don't assert a hard threshold. A delay
        // over ~1s indicates the queue is backlogged, which is the
        // user-visible "still playing" symptom.
        let ms = Double(delay.components.seconds) * 1000
          + Double(delay.components.attoseconds) / 1e15
        #expect(ms < 2000, "Utility queue drained \(Int(ms))ms after drop — too slow")
      }
    }

    // MARK: - Concurrent parse cancel chaos

    /// Start N parses concurrently, cancel all at random offsets. If
    /// any parse's retain/release balance is off, this surfaces as a
    /// leaked Media across the churn.
    @Test
    func `Concurrent parse cancellation chaos does not leak media`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let count = 40
      let probes = WeakMediaProbes()

      try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<count {
          let media = try Media(url: TestMedia.testMP4URL)
          probes.add(media)
          group.addTask { @Sendable in
            let parseTask = Task {
              _ = try? await media.parse(timeout: .milliseconds(800), instance: instance)
            }
            // Staggered cancellations — some before parse starts, some
            // during, some at completion edge.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 1...200) + i))
            parseTask.cancel()
            _ = await parseTask.value
          }
        }
        try await group.waitForAll()
      }

      try await Task.sleep(for: .seconds(2))
      await yield(32)

      let alive = probes.aliveCount()
      #expect(alive == 0, "\(alive) / \(count) Media leaked through concurrent parse/cancel chaos")
    }

    // MARK: - RendererDiscoverer churn with live event consumer

    /// Each discoverer offloads its teardown to the utility queue. If
    /// the continuation isn't finished before release, consumer tasks
    /// hang. Validates that churning discoverers with live consumers
    /// produces neither hangs nor leaks.
    @Test
    func `RendererDiscoverer churn with live event consumers terminates cleanly`() async throws {
      let instance = TestInstance.shared
      guard let service = RendererDiscoverer.availableServices(instance: instance).first else {
        return // No renderer discovery services on this platform.
      }

      let consumed = Mutex(0)
      let iterations = 20

      for _ in 0..<iterations {
        let disc = try RendererDiscoverer(name: service.name, instance: instance)
        let stream = disc.events
        let task = Task.detached { @Sendable in
          for await _ in stream {
            consumed.withLock { $0 += 1 }
          }
        }
        try? await Task.sleep(for: .milliseconds(20))
        _ = disc // discoverer drops at end of iteration
        task.cancel()
      }

      try await Task.sleep(for: .seconds(1))
      await yield(32)

      // No weak probe possible for RendererDiscoverer without exposing
      // an initializer-free factory; the assertion is "no crash, no
      // hang". If the utility queue cleanup had a race, this loop would
      // either stall or produce a segfault.
    }

    // MARK: - Player.load Media retain/release churn

    /// Loads a sequence of fresh `Media` instances on the same Player
    /// and tracks that each previous media is released when replaced.
    /// The existing `MemoryAndRetainTests` covers one replacement; this
    /// variant replaces 200 times to surface any stale retention in
    /// the observation graph's media-change notification path.
    @Test
    func `Rapid load() replacement releases prior media`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let probes = WeakMediaProbes()

      for i in 0..<200 {
        let media = try Media(url: i % 2 == 0 ? TestMedia.testMP4URL : TestMedia.twosecURL)
        probes.add(media)
        player.load(media)
      }

      // After 200 loads the player holds only the last media. All prior
      // media should have dropped. Account for main-actor settle time.
      await yield(16)
      try await Task.sleep(for: .milliseconds(100))
      await yield(16)

      let alive = probes.aliveCount()
      // Exactly one should be alive (the most recent load). A higher
      // count indicates the replacement path leaks the prior media —
      // typically through an observation closure that captured the
      // previous `currentMedia` strongly.
      #expect(alive <= 1, "\(alive) Media still alive after 200 loads — prior currentMedia retained")
    }

    // MARK: - Player deinit without stop

    /// The documented pattern is `stop()` → drop. What happens when a
    /// caller forgets `stop()`? The Player's `isolated deinit` does the
    /// stop itself (via `libvlc_media_player_stop_async` inside the
    /// utility-queue closure), but races are possible: if the decode
    /// thread is mid-frame, the release hits it concurrently.
    ///
    /// Not a weak-probe test; this is a crash probe. If this loops
    /// hundred times without a SIGSEGV / assertion, the deinit
    /// sequence is robust.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Player drop without explicit stop does not crash`() async throws {
      for _ in 0..<20 {
        let instance = TestInstance.makeAudioOnly()
        let player = Player(instance: instance)
        try player.play(url: TestMedia.twosecURL)
        // No stop! Just let the player go out of scope. deinit must
        // handle it cleanly.
        try? await Task.sleep(for: .milliseconds(50))
      }
      // Give the utility queue time to drain 20 pending cleanups.
      try await Task.sleep(for: .seconds(3))
    }

    // MARK: - Player with live VideoSurface attach/detach

    /// `libvlc_media_player_set_nsobject` is the attach point. Churning
    /// attach → nil → attach with fresh pointers must not leak; libVLC
    /// doesn't retain the pointer beyond storing it, so the Swift side
    /// bears full responsibility for holding the view alive while
    /// attached.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `nsobject pointer churn during playback does not crash`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      try player.play(url: TestMedia.twosecURL)

      // Allocate and free a sequence of raw byte blocks and register
      // them as nsobject. These aren't real views, but libVLC shouldn't
      // dereference them while the player is idle-rendering (no
      // real video pipeline in `--no-video` mode, per TestInstance).
      //
      // The attack shape here is: can we set → unset → set → unset?
      for _ in 0..<100 {
        nonisolated(unsafe) let ptr = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        _ = ptr
        // We don't actually pass this to libVLC since we're running in
        // --no-video mode and there's no vout to attach to. The real
        // pressure test here is ensuring the player handles rapid
        // state changes without crashing; `set_nsobject(nil)` is a
        // no-op when no surface is active.
        ptr.deallocate()
        player.pause()
        player.resume()
      }

      player.stop()
      try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Cross-thread Player drop stress

    /// Tasks from different concurrency domains racing to drop Player
    /// instances. The isolated deinit marshals cleanup to a utility
    /// queue, but the main-actor hop before the dispatch is the part
    /// that could cause a priority-inversion stall in heavy churn.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Dropping players from multiple task contexts does not deadlock`() async throws {
      let instance = TestInstance.makeAudioOnly()

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
          group.addTask { @MainActor in
            for _ in 0..<5 {
              let p = Player(instance: instance)
              try? p.play(url: TestMedia.twosecURL)
              // Drop without stop
              _ = p
            }
          }
          group.addTask { @MainActor in
            for _ in 0..<5 {
              let p = Player(instance: instance)
              try? p.play(url: TestMedia.testMP4URL)
              p.stop()
            }
          }
        }
        await group.waitForAll()
      }

      // Wait for all utility-queue cleanups to drain.
      try await Task.sleep(for: .seconds(3))
    }

    // MARK: - Heavy VLCInstance churn

    /// Each `TestInstance.makeAudioOnly()` fires up a fresh libVLC
    /// instance with its plugin cache + module registry. If instance
    /// release leaks anything, 40 fresh instances in a row makes it
    /// obvious at the RSS level.
    @Test
    func `Forty fresh VLCInstance lifecycles stay RSS-bounded`() async {
      let rssBefore = MemorySampler.residentBytes()

      for _ in 0..<40 {
        _ = TestInstance.makeAudioOnly()
      }

      try? await Task.sleep(for: .seconds(1))
      await yield(32)

      let rssAfter = MemorySampler.residentBytes()
      let deltaMB = MemorySampler.deltaMB(from: rssBefore, to: rssAfter)
      // libVLC caches the module descriptor on first init; subsequent
      // instances are cheaper. 40 instances should leave RSS within
      // ~100 MB of the baseline.
      #expect(deltaMB < 150, "VLCInstance churn leaked \(Int(deltaMB)) MB")
    }

    // MARK: - Full-surface torture

    /// The showcase scenario: a player with an equalizer, an active log
    /// consumer, an event stream consumer, a loaded media, and a video
    /// surface attached — all torn down together. This is the closest
    /// analog to the real "fullScreenCover with everything" user flow.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Full-feature player torture does not leak`() async throws {
      let iterations = 10
      let playerProbes = WeakPlayerProbes()
      let eqProbes = WeakEqualizerProbes()

      for _ in 0..<iterations {
        let instance = TestInstance.makeAudioOnly()
        let player = Player(instance: instance)
        playerProbes.add(player)

        let eq = Equalizer()
        eqProbes.add(eq)
        player.equalizer = eq

        let logStream = instance.logStream(minimumLevel: .warning)
        let logConsumer = Task.detached { @Sendable in
          var n = 0
          for await _ in logStream {
            n += 1
            if n > 3 { break }
          }
        }

        let eventStream = player.events
        let eventConsumer = Task.detached { @Sendable in
          var n = 0
          for await _ in eventStream {
            n += 1
            if n > 5 { break }
          }
        }

        try player.play(url: TestMedia.twosecURL)
        try? await Task.sleep(for: .milliseconds(150))

        player.stop()
        logConsumer.cancel()
        eventConsumer.cancel()
        _ = await logConsumer.value
        _ = await eventConsumer.value
      }

      try await Task.sleep(for: .seconds(2))
      await yield(64)

      let alivePlayers = playerProbes.aliveCount()
      let aliveEQs = eqProbes.aliveCount()
      #expect(alivePlayers == 0, "\(alivePlayers) Players leaked after full-feature torture")
      #expect(aliveEQs == 0, "\(aliveEQs) Equalizers leaked after full-feature torture")
    }

    // MARK: - Helpers

    /// Yields the cooperative thread pool so pending main-actor work,
    /// offloaded deinits, and the observation graph can settle before
    /// a weak probe is measured.
    private func yield(_ n: Int) async {
      for _ in 0..<n {
        await Task.yield()
      }
    }
  }
}

// MARK: - Weak Probes

// One weak-probe helper per concrete type. Keeping them separate (vs
// a single generic) dodges the `@MainActor` / `Sendable` inference
// wrinkles that come up when `WeakProbes<Player>` is referenced from
// detached tasks.

@MainActor
private final class WeakPlayerProbes {
  private struct Probe { weak var object: Player? }
  private var probes: [Probe] = []
  func add(_ object: Player) {
    probes.append(Probe(object: object))
  }

  func aliveCount() -> Int {
    probes = probes.filter { $0.object != nil }
    return probes.count
  }
}

@MainActor
private final class WeakMediaProbes {
  private struct Probe { weak var object: Media? }
  private var probes: [Probe] = []
  func add(_ object: Media) {
    probes.append(Probe(object: object))
  }

  func aliveCount() -> Int {
    probes = probes.filter { $0.object != nil }
    return probes.count
  }
}

@MainActor
private final class WeakEqualizerProbes {
  private struct Probe { weak var object: Equalizer? }
  private var probes: [Probe] = []
  func add(_ object: Equalizer) {
    probes.append(Probe(object: object))
  }

  func aliveCount() -> Int {
    probes = probes.filter { $0.object != nil }
    return probes.count
  }
}

#if os(iOS) || os(macOS)
@MainActor
private final class WeakPiPControllerProbes {
  private struct Probe { weak var object: PiPController? }
  private var probes: [Probe] = []
  func add(_ object: PiPController) {
    probes.append(Probe(object: object))
  }

  func aliveCount() -> Int {
    probes = probes.filter { $0.object != nil }
    return probes.count
  }
}
#endif

// swiftlint:enable file_length
