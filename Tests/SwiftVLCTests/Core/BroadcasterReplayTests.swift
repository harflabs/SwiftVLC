@testable import SwiftVLC
import Testing

extension Integration {
  /// ``Broadcaster/subscribeReplayingLatest(policy:filter:)`` exists for state a
  /// late subscriber has to know rather than wait for. A transitions-only stream
  /// cannot tell it the current value, and reading a separate property races the
  /// stream it is trying to line up with.
  @Suite(.tags(.logic))
  struct BroadcasterReplayTests {
    @Test
    func `A late subscriber receives the most recent element first`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(1)
      broadcaster.broadcast(2)

      let stream = broadcaster.subscribeReplayingLatest(policy: .unbounded)
      broadcaster.broadcast(3)
      broadcaster.terminate()

      var received: [Int] = []
      for await value in stream {
        received.append(value)
      }

      // 2 replayed, then 3 live. 1 is gone: this replays the latest, not a log.
      #expect(received == [2, 3])
    }

    /// The case that motivates retaining the element at all. Recording it only
    /// when someone is listening would leave the first subscriber with nothing,
    /// which is precisely the subscriber that needs it.
    @Test
    func `An element broadcast with no subscribers is still replayed`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(7)

      let stream = broadcaster.subscribeReplayingLatest(policy: .unbounded)
      broadcaster.terminate()

      var received: [Int] = []
      for await value in stream {
        received.append(value)
      }

      #expect(received == [7])
    }

    @Test
    func `Replay yields nothing when nothing has been broadcast`() async {
      let broadcaster = Broadcaster<Int>()
      let stream = broadcaster.subscribeReplayingLatest(policy: .unbounded)
      broadcaster.terminate()

      var received: [Int] = []
      for await value in stream {
        received.append(value)
      }

      #expect(received.isEmpty)
    }

    /// A replayed element the filter rejects must not be smuggled past it. The
    /// filter is the subscriber's statement about what it can handle, and it
    /// does not stop applying because an element arrived by replay.
    @Test
    func `The subscriber filter applies to the replayed element`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(1)

      let stream = broadcaster.subscribeReplayingLatest(
        policy: .unbounded,
        filter: { $0.isMultiple(of: 2) }
      )
      broadcaster.broadcast(4)
      broadcaster.terminate()

      var received: [Int] = []
      for await value in stream {
        received.append(value)
      }

      #expect(received == [4])
    }

    /// The default path is unchanged. Replay is opt-in because it is actively
    /// wrong for a consumer awaiting the *next* occurrence of something:
    /// `recast(to:)` captures the transition stream before `play()`, and a
    /// replayed `.playing` from the outgoing session would let it report
    /// success before the replacement ever started.
    @Test
    func `A plain subscriber receives no replay`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(1)

      let stream = broadcaster.subscribe(policy: .unbounded)
      broadcaster.broadcast(2)
      broadcaster.terminate()

      var received: [Int] = []
      for await value in stream {
        received.append(value)
      }

      #expect(received == [2])
    }

    @Test
    func `Clearing replay preserves live subscribers but not stale seeding`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(1)
      let existing = broadcaster.subscribeReplayingLatest(policy: .unbounded)

      broadcaster.clearReplay()
      let afterBoundary = broadcaster.subscribeReplayingLatest(policy: .unbounded)
      broadcaster.broadcast(2)
      broadcaster.terminate()

      var existingValues: [Int] = []
      for await value in existing {
        existingValues.append(value)
      }
      var boundaryValues: [Int] = []
      for await value in afterBoundary {
        boundaryValues.append(value)
      }

      #expect(existingValues == [1, 2])
      #expect(boundaryValues == [2])
    }

    /// Every subscriber converges on the same value without waiting for another
    /// transition, which is what makes this usable for shared state.
    @Test
    func `Multiple replaying subscribers all see the same latest element`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(42)

      let first = broadcaster.subscribeReplayingLatest(policy: .unbounded)
      let second = broadcaster.subscribeReplayingLatest(policy: .unbounded)
      broadcaster.terminate()

      var a: [Int] = []
      for await value in first {
        a.append(value)
      }
      var b: [Int] = []
      for await value in second {
        b.append(value)
      }

      #expect(a == [42])
      #expect(b == [42])
    }

    /// A terminated broadcaster hands back a finished stream, replay or not.
    @Test
    func `A replaying subscriber to a terminated broadcaster gets nothing`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.broadcast(1)
      broadcaster.terminate()

      var received: [Int] = []
      for await value in broadcaster.subscribeReplayingLatest(policy: .unbounded) {
        received.append(value)
      }

      #expect(received.isEmpty)
    }
  }
}
