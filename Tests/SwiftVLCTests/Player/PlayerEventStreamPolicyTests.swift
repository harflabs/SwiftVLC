@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// Delivery guarantees of the policy-aware event-stream API:
/// `events(policy:filter:)`, `stateTransitions`, and the per-instance
/// log-broadcaster lifecycle. Split in two suites — the first runs
/// headless on CI (no playback), the second drives real playback and is
/// gated on `TestCondition.canPlayMedia`.
extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerEventStreamPolicyTests {
    /// Forces the playback-free native-handle swap with a live event
    /// stream attached, then loads media: libVLC emits `MediaChanged`
    /// on the *new* handle's event manager, so the event only reaches
    /// the stream if the bridge reattached during the swap.
    @Test(.timeLimit(.minutes(1)))
    func `Same stream survives the native handle swap and yields events from the new handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let stream = player.events(policy: .unbounded, filter: nil)

      let sawMediaChanged = Mutex(false)
      let finished = Mutex(false)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .mediaChanged = event {
            sawMediaChanged.withLock { $0 = true }
          }
        }
        finished.withLock { $0 = true }
      }

      let oldPointer = player.pointer
      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()
      try #require(
        player.pointer != oldPointer,
        "swap did not replace the native player handle"
      )

      let media = try Media(url: TestMedia.testMP4URL)
      player.load(media)
      try #require(
        await poll(until: { sawMediaChanged.withLock { $0 } }),
        "Waiting for: mediaChanged from the replacement handle"
      )
      #expect(
        !finished.withLock { $0 },
        "event stream finished across the swap instead of surviving reattach"
      )
      collector.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func `Non-shared instance releases its log broadcaster graph`() async throws {
      weak var probe: AnyObject?
      do {
        let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--quiet"])
        probe = instance.logBroadcaster._broadcasterForTesting
        let logs = instance.logStream(minimumLevel: .warning)
        let consumer = Task.detached { @Sendable in
          for await _ in logs {}
        }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value
      }

      let released = try await poll(timeout: .seconds(3), until: { probe == nil })
      try #require(released, "Broadcaster<LogEntry> graph survived instance deinit")
    }

    /// Buries a one-shot `.lengthChanged` under a `.timeChanged`
    /// firehose, broadcast synchronously from the main actor so the
    /// player's main-actor consumer task cannot drain in between. The
    /// discriminator sits on the oldest side of the backlog — a lossy
    /// newest-wins buffer would evict it, so `duration` only mirrors it
    /// if the internal subscription buffers without bound.
    @Test(.timeLimit(.minutes(1)))
    func `Internal consumer mirrors a buried one-shot event after a main-actor stall`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)

      bridge._broadcastForTesting(.lengthChanged(.seconds(2)), source: source)
      for _ in 0..<128 {
        bridge._broadcastForTesting(.timeChanged(.zero), source: source)
      }

      try #require(
        await poll(until: { player.duration == .seconds(2) }),
        "Waiting for: duration mirrored through the backlog"
      )
    }

    /// Policy and filter must travel together from `Player.events`
    /// through the bridge into the per-subscription buffer: the filter
    /// keeps the `.timeChanged` firehose out while the unbounded buffer
    /// preserves both one-shot state changes broadcast before the
    /// consumer drains. A `.mediaChanged` sentinel bounds the drain.
    @Test(.timeLimit(.minutes(1)))
    func `Unbounded policy and filter combine on the public events stream`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)
      let stream = player.events(policy: .unbounded, filter: { event in
        if case .timeChanged = event {
          return false
        }
        return true
      })

      bridge._broadcastForTesting(.stateChanged(.opening), source: source)
      for _ in 0..<150 {
        bridge._broadcastForTesting(.timeChanged(.zero), source: source)
      }
      bridge._broadcastForTesting(.stateChanged(.playing), source: source)
      bridge._broadcastForTesting(.mediaChanged, source: source)

      var states: [PlayerState] = []
      var timeChangedCount = 0
      drain: for await event in stream {
        switch event {
        case .stateChanged(let state):
          states.append(state)
        case .timeChanged:
          timeChangedCount += 1
        case .mediaChanged:
          break drain
        default:
          continue
        }
      }

      #expect(states == [.opening, .playing], "state changes lost or reordered: \(states)")
      #expect(timeChangedCount == 0, "firehose events leaked through the filter")
    }

    /// `stateTransitions` keeps every lifecycle transition, in order,
    /// while a 100-event `.timeChanged` burst in the middle of the
    /// sequence never reaches the stream.
    @Test(.timeLimit(.minutes(1)))
    func `stateTransitions is lossless and firehose-free without playback`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let source = Player.sourceIdentifier(for: player.pointer)
      let transitions = player.stateTransitions

      let collected = Mutex<[PlayerState]>([])
      let collector = Task.detached { @Sendable in
        for await state in transitions {
          collected.withLock { $0.append(state) }
        }
      }

      bridge._broadcastForTesting(.stateChanged(.opening), source: source)
      bridge._broadcastForTesting(.stateChanged(.playing), source: source)
      for _ in 0..<100 {
        bridge._broadcastForTesting(.timeChanged(.zero), source: source)
      }
      bridge._broadcastForTesting(.stateChanged(.stopping), source: source)
      bridge._broadcastForTesting(.stateChanged(.stopped), source: source)

      try #require(
        await poll(until: { collected.withLock { $0.count >= 4 } }),
        "Waiting for: four lifecycle transitions collected"
      )
      collector.cancel()

      #expect(
        collected.withLock { $0 } == [.opening, .playing, .stopping, .stopped],
        "transitions lossy, reordered, or polluted: \(collected.withLock { $0 })"
      )
    }
  }

  @Suite(.tags(.mainActor, .async), .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"))
  @MainActor struct PlayerEventStreamPolicyPlaybackTests {
    /// Stalls an `.unbounded` consumer across a full playback session so
    /// the backlog grows far past the default 64-element buffer, then
    /// requires the one-shot `.stateChanged(.stopped)` to still be in
    /// the drained backlog. A parallel `.newest(1)` subscription shows
    /// the lossy counterpoint: at most one element survives the stall.
    @Test(.timeLimit(.minutes(1)))
    func `Unbounded subscription delivers the terminal transition under backlog`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let unbounded = player.events(policy: .unbounded, filter: nil)
      let newestOne = player.events(policy: .newest(1), filter: nil)

      let stallReleased = Mutex(false)
      let sawStopped = Mutex(false)
      let collector = Task.detached { @Sendable in
        while !stallReleased.withLock({ $0 }) {
          try? await Task.sleep(for: .milliseconds(10))
        }
        for await event in unbounded {
          if case .stateChanged(.stopped) = event {
            sawStopped.withLock { $0 = true }
            break
          }
        }
      }

      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      try #require(
        await poll(timeout: .seconds(10), until: { player.currentTime >= .seconds(1) }),
        "Waiting for: enough playback to overflow a default buffer"
      )
      player.stop()
      try #require(
        await poll(until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped"
      )

      stallReleased.withLock { $0 = true }
      try #require(
        await poll(timeout: .seconds(5), until: { sawStopped.withLock { $0 } }),
        "Waiting for: stopped transition delivered from the backlog"
      )
      collector.cancel()

      let newestBuffered = Mutex(0)
      let drainer = Task.detached { @Sendable in
        for await _ in newestOne {
          newestBuffered.withLock { $0 += 1 }
        }
      }
      try await Task.sleep(for: .milliseconds(300))
      drainer.cancel()
      #expect(
        newestBuffered.withLock { $0 } <= 1,
        "newest(1) subscription buffered more than one element across the stall"
      )
    }

    @Test(.timeLimit(.minutes(1)))
    func `Subscription filter keeps the firehose out`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: { event in
        if case .stateChanged = event {
          return true
        }
        return false
      })

      let received = Mutex<[PlayerEvent]>([])
      let collector = Task.detached { @Sendable in
        for await event in stream {
          received.withLock { $0.append(event) }
        }
      }

      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      try #require(
        await poll(timeout: .seconds(10), until: { player.currentTime >= .seconds(1) }),
        "Waiting for: ~1s of playback firehose"
      )
      player.stop()
      try #require(
        await poll(until: {
          received.withLock { events in
            events.contains { event in
              if case .stateChanged(.stopped) = event {
                return true
              }
              return false
            }
          }
        }),
        "Waiting for: stopped transition through the filter"
      )
      collector.cancel()

      let snapshot = received.withLock { $0 }
      #expect(!snapshot.isEmpty)
      for event in snapshot {
        switch event {
        case .stateChanged:
          continue
        case .timeChanged, .positionChanged, .bufferingProgress:
          Issue.record("firehose event leaked through the filter: \(event)")
        default:
          Issue.record("unexpected event leaked through the filter: \(event)")
        }
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func `stateTransitions is lossless and lifecycle-only`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let transitions = player.stateTransitions

      let collected = Mutex<[PlayerState]>([])
      let collector = Task.detached { @Sendable in
        for await state in transitions {
          collected.withLock { $0.append(state) }
        }
      }

      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      player.stop()
      try #require(
        await poll(until: { collected.withLock { $0.contains(.stopped) } }),
        "Waiting for: stopped transition collected"
      )
      collector.cancel()

      let snapshot = collected.withLock { $0 }
      let playingIndex = try #require(snapshot.firstIndex(of: .playing))
      let terminalIndex = try #require(
        snapshot.firstIndex(where: { $0 == .stopped || $0 == .stopping })
      )
      #expect(
        playingIndex < terminalIndex,
        "playing did not precede the terminal transition: \(snapshot)"
      )
      #expect(snapshot.count <= 10, "stateTransitions delivered a firehose: \(snapshot)")
    }

    /// The filter runs on libVLC's event thread for every broadcast; one
    /// that re-enters the player's event surface (creating and dropping
    /// a fresh subscription per event) must not deadlock the broadcaster
    /// or stall delivery to the original subscriber.
    @Test(.timeLimit(.minutes(1)))
    func `Re-entrant filter does not deadlock`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let received = Mutex(0)
      let stream = player.events(policy: .unbounded, filter: { _ in
        _ = player.events(policy: .newest(4), filter: nil)
        return true
      })

      let collector = Task.detached { @Sendable in
        for await _ in stream {
          received.withLock { $0 += 1 }
        }
      }

      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      try #require(
        await poll(until: { received.withLock { $0 } > 0 }),
        "Waiting for: events delivered through the re-entrant filter"
      )
      player.stop()
      collector.cancel()
    }
  }
}
