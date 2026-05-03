@testable import SwiftVLC
import Synchronization
import Testing

extension Logic {
  struct BroadcasterTests {
    // MARK: - Basic broadcast

    @Test func `single subscriber receives every broadcast`() async {
      let broadcaster = Broadcaster<Int>()
      let stream = broadcaster.subscribe()

      Task.detached {
        for value in 1...5 {
          broadcaster.broadcast(value)
        }
        broadcaster.finishAll()
      }

      var received: [Int] = []
      for await value in stream {
        received.append(value)
      }

      #expect(received == [1, 2, 3, 4, 5])
    }

    @Test func `multiple subscribers each receive every broadcast`() async {
      let broadcaster = Broadcaster<Int>()
      let stream1 = broadcaster.subscribe()
      let stream2 = broadcaster.subscribe()
      let stream3 = broadcaster.subscribe()

      Task.detached {
        for value in 1...3 {
          broadcaster.broadcast(value)
        }
        broadcaster.finishAll()
      }

      async let r1: [Int] = collect(stream1)
      async let r2: [Int] = collect(stream2)
      async let r3: [Int] = collect(stream3)

      let (got1, got2, got3) = await (r1, r2, r3)
      #expect(got1 == [1, 2, 3])
      #expect(got2 == [1, 2, 3])
      #expect(got3 == [1, 2, 3])
    }

    @Test func `subscriber filter excludes non-matching broadcasts`() async {
      let broadcaster = Broadcaster<Int>()
      let evens = broadcaster.subscribe(filter: { $0 % 2 == 0 })

      Task.detached {
        for value in 1...6 {
          broadcaster.broadcast(value)
        }
        broadcaster.finishAll()
      }

      let received = await collect(evens)
      #expect(received == [2, 4, 6])
    }

    @Test func `unsubscribe via stream termination removes subscriber`() async {
      let broadcaster = Broadcaster<Int>()

      do {
        let stream = broadcaster.subscribe()
        // Take only the first element, then drop the stream so its
        // continuation finishes via deinit.
        var iter = stream.makeAsyncIterator()
        Task.detached { broadcaster.broadcast(42) }
        _ = await iter.next()
      }

      // Give onTermination a moment to fire.
      try? await Task.sleep(for: .milliseconds(50))
      #expect(broadcaster.isEmpty)
    }

    @Test func `finishAll closes every active stream`() async {
      let broadcaster = Broadcaster<Int>()
      let stream1 = broadcaster.subscribe()
      let stream2 = broadcaster.subscribe()

      broadcaster.finishAll()

      let r1: [Int] = await collect(stream1)
      let r2: [Int] = await collect(stream2)
      #expect(r1.isEmpty)
      #expect(r2.isEmpty)
      #expect(broadcaster.isEmpty)
    }

    @Test func `finishAll allows new subscribers to attach`() async {
      let broadcaster = Broadcaster<Int>()
      let s1 = broadcaster.subscribe()
      broadcaster.finishAll()
      _ = await collect(s1)

      // A new subscriber attaches normally and receives broadcasts.
      let s2 = broadcaster.subscribe()
      Task.detached {
        broadcaster.broadcast(42)
        broadcaster.finishAll()
      }
      let received = await collect(s2)
      #expect(received == [42])
    }

    // MARK: - terminate

    @Test func `terminate closes existing subscribers`() async {
      let broadcaster = Broadcaster<Int>()
      let stream = broadcaster.subscribe()

      broadcaster.terminate()

      let received: [Int] = await collect(stream)
      #expect(received.isEmpty)
    }

    @Test func `terminate makes future subscribe return finished stream`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.terminate()

      // Subsequent subscribe must hand back an already-finished stream
      // so for-await loops exit immediately without blocking.
      let stream = broadcaster.subscribe()
      let received: [Int] = await collect(stream)
      #expect(received.isEmpty)
    }

    @Test func `terminate makes broadcast a no-op`() async {
      let broadcaster = Broadcaster<Int>()
      broadcaster.terminate()

      // After terminate, broadcast must not yield to any future
      // subscribers — they're handed already-finished streams.
      broadcaster.broadcast(1)
      broadcaster.broadcast(2)

      let stream = broadcaster.subscribe()
      let received: [Int] = await collect(stream)
      #expect(received.isEmpty)
    }

    @Test func `terminate fires onLastUnsubscribed when subscribers were active`() async {
      let lastCount = Mutex(0)
      let broadcaster = Broadcaster<Int>(
        onLastUnsubscribed: { lastCount.withLock { $0 += 1 } }
      )

      let stream = broadcaster.subscribe()
      try? await Task.sleep(for: .milliseconds(50))

      broadcaster.terminate()
      try? await Task.sleep(for: .milliseconds(100))

      #expect(lastCount.withLock { $0 } == 1)
      _ = stream
    }

    // MARK: - hasSubscriber probes

    @Test func `hasSubscriber matching probe respects filters`() {
      let broadcaster = Broadcaster<Int>()
      // Bind the streams so their continuations aren't immediately dropped.
      let s1 = broadcaster.subscribe(filter: { $0 > 10 })
      let s2 = broadcaster.subscribe(filter: { $0 < 0 })

      #expect(broadcaster.hasSubscriber(matching: 5) == false)
      #expect(broadcaster.hasSubscriber(matching: 100) == true)
      #expect(broadcaster.hasSubscriber(matching: -1) == true)

      _ = (s1, s2) // keep streams alive through the assertions
    }

    @Test func `isEmpty reflects subscriber count`() {
      let broadcaster = Broadcaster<Int>()
      #expect(broadcaster.isEmpty)

      let stream = broadcaster.subscribe()
      #expect(!broadcaster.isEmpty)

      broadcaster.finishAll()
      #expect(broadcaster.isEmpty)
      _ = stream
    }

    // MARK: - Lifecycle callbacks

    @Test func `onFirstSubscriber fires once when count goes 0 to 1`() async {
      let counter = Mutex(0)
      let broadcaster = Broadcaster<Int>(
        onFirstSubscriber: {
          counter.withLock { $0 += 1 }
        }
      )

      let s1 = broadcaster.subscribe()
      let s2 = broadcaster.subscribe()
      let s3 = broadcaster.subscribe()

      // Reconciliation runs on a private serial queue; give it time.
      try? await Task.sleep(for: .milliseconds(100))
      #expect(counter.withLock { $0 } == 1)
      _ = (s1, s2, s3)
    }

    @Test func `onLastUnsubscribed fires when count goes back to 0`() async {
      let firstCount = Mutex(0)
      let lastCount = Mutex(0)
      let broadcaster = Broadcaster<Int>(
        onFirstSubscriber: { firstCount.withLock { $0 += 1 } },
        onLastUnsubscribed: { lastCount.withLock { $0 += 1 } }
      )

      do {
        let stream = broadcaster.subscribe()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(firstCount.withLock { $0 } == 1)
        _ = stream
      }
      // Stream goes out of scope here; onTermination → unsubscribe.
      try? await Task.sleep(for: .milliseconds(150))
      #expect(lastCount.withLock { $0 } == 1)
    }

    @Test func `onFirstSubscriber fires again after a full unsubscribe cycle`() async {
      let firstCount = Mutex(0)
      let broadcaster = Broadcaster<Int>(
        onFirstSubscriber: { firstCount.withLock { $0 += 1 } }
      )

      do {
        let stream = broadcaster.subscribe()
        try? await Task.sleep(for: .milliseconds(50))
        _ = stream
      }
      try? await Task.sleep(for: .milliseconds(100))
      do {
        let stream = broadcaster.subscribe()
        try? await Task.sleep(for: .milliseconds(50))
        _ = stream
      }
      try? await Task.sleep(for: .milliseconds(100))

      #expect(firstCount.withLock { $0 } == 2)
    }

    // MARK: - Concurrency stress

    @Test func `concurrent broadcasts and subscriptions do not deadlock or crash`() async {
      let broadcaster = Broadcaster<Int>()
      let producerCount = 4
      let perProducer = 100
      let consumerCount = 4

      await withTaskGroup(of: Void.self) { group in
        for c in 0..<consumerCount {
          group.addTask {
            let stream = broadcaster.subscribe()
            var iter = stream.makeAsyncIterator()
            // Drain a few elements to exercise the yield path under contention.
            for _ in 0..<10 {
              _ = await iter.next()
            }
            _ = c
          }
        }

        for p in 0..<producerCount {
          group.addTask { @Sendable in
            for i in 0..<perProducer {
              broadcaster.broadcast(p * perProducer + i)
            }
          }
        }

        await group.waitForAll()
      }

      broadcaster.finishAll()
    }
  }
}

// MARK: - Helpers

private func collect<S: AsyncSequence & Sendable>(
  _ stream: S
)
  async -> [S.Element] where S.Element: Sendable {
  var result: [S.Element] = []
  do {
    for try await value in stream {
      result.append(value)
    }
  } catch {
    // Streams in this test never throw; ignore.
  }
  return result
}
