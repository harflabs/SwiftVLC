#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Dispatch
import Foundation
import Synchronization
import Testing

/// AVKit's synchronous PiP callbacks must answer while the main actor is busy.
///
/// The deadlock this guards against is a cycle: the main thread waits on
/// libVLC or video-output teardown, that teardown is gated behind an AVKit
/// callback thread, and the callback thread is parked in
/// `DispatchQueue.main.sync`. Removing the last edge — callbacks never wait on
/// main — is what makes the cycle impossible, so these tests pin that the
/// synchronous queries return *without* the main actor being available.
@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct PiPCallbackForwardProgressTests {
  /// The paused query has to answer from a background thread while the main
  /// thread is blocked. Before the fix this call would sit in
  /// `DispatchQueue.main.sync` until the stall ended.
  @Test
  func `The paused query answers while the main thread is blocked`() {
    let proxy = PiPPlaybackDelegateProxy()
    let released = DispatchSemaphore(value: 0)
    let stalled = DispatchSemaphore(value: 0)

    // Occupy the main thread for the duration of the query.
    DispatchQueue.main.async {
      stalled.signal()
      released.wait()
    }
    #expect(stalled.wait(timeout: .now() + 5) == .success)

    let answered = DispatchSemaphore(value: 0)
    let result = Mutex<Bool?>(nil)
    DispatchQueue.global().async {
      result.withLock { $0 = proxy.resolveIsPlaybackPaused() }
      answered.signal()
    }

    let progressed = answered.wait(timeout: .now() + 3) == .success
    released.signal()

    #expect(progressed, "the paused query blocked on a stalled main actor")
    // No owner attached, so it reports the stable default rather than
    // inventing playback.
    #expect(result.withLock { $0 } == true)
  }

  /// Same guarantee for the time-range query, which additionally has to reach
  /// libVLC — that call happens after the snapshot lock is released.
  @Test
  func `The time-range query answers while the main thread is blocked`() {
    let proxy = PiPPlaybackDelegateProxy()
    let released = DispatchSemaphore(value: 0)
    let stalled = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      stalled.signal()
      released.wait()
    }
    #expect(stalled.wait(timeout: .now() + 5) == .success)

    let answered = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = proxy.resolveTimeRangeForPlayback()
      answered.signal()
    }

    let progressed = answered.wait(timeout: .now() + 3) == .success
    released.signal()

    #expect(progressed, "the time-range query blocked on a stalled main actor")
  }

  /// A query reads the pointer and timebase in one lock acquisition, so it can
  /// never assemble a range from two different generations.
  @Test
  func `A query never mixes generations`() throws {
    let snapshot = Mutex(PiPCallbackSnapshot())
    let first = try #require(OpaquePointer(bitPattern: 0x1))
    let second = try #require(OpaquePointer(bitPattern: 0x2))

    snapshot.withLock {
      $0.playerPointer = first
      $0.generation = 7
    }

    let observed = snapshot.withLock { $0 }

    // A concurrent republication cannot retroactively change what the reader
    // already took.
    snapshot.withLock {
      $0.playerPointer = second
      $0.generation = 8
    }

    #expect(observed.playerPointer == first)
    #expect(observed.generation == 7)
    #expect(snapshot.withLock { $0.generation } == 8)
  }

  /// An unattached snapshot reports "not attached" so queries fall back to
  /// stable defaults instead of dereferencing a released handle.
  @Test
  func `An invalidated snapshot reports as unattached`() {
    let snapshot = Mutex(PiPCallbackSnapshot())
    snapshot.withLock { $0.playerPointer = try? #require(OpaquePointer(bitPattern: 0x1)) }
    #expect(snapshot.withLock { $0.isAttached })

    snapshot.withLock {
      $0.playerPointer = nil
      $0.generation &+= 1
    }

    #expect(!snapshot.withLock { $0.isAttached })
  }

  /// The bounded hop is the one remaining blocking call. It must give up and
  /// return the fallback rather than joining a wedged main actor.
  @Test
  func `The bounded main-actor hop degrades instead of deadlocking`() {
    let released = DispatchSemaphore(value: 0)
    let stalled = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      stalled.signal()
      released.wait()
    }
    #expect(stalled.wait(timeout: .now() + 5) == .success)

    let answered = DispatchSemaphore(value: 0)
    let result = Mutex<Bool?>(nil)
    DispatchQueue.global().async {
      let value = pipMainActorSyncBounded(timeout: .milliseconds(50), fallback: true) {
        false
      }
      result.withLock { $0 = value }
      answered.signal()
    }

    let progressed = answered.wait(timeout: .now() + 3) == .success
    released.signal()

    #expect(progressed, "the bounded hop never returned")
    #expect(result.withLock { $0 } == true, "it returned the main-actor value, not the fallback")
  }

  /// After the bounded hop gives up, the queued body must not run.
  ///
  /// For the close veto that body reparents the replacement window — running
  /// it once the caller has already told AppKit the close was allowed would
  /// apply UI side effects for a decision that was never delivered.
  @Test
  func `A timed-out bounded hop does not run its body afterwards`() {
    let released = DispatchSemaphore(value: 0)
    let stalled = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      stalled.signal()
      released.wait()
    }
    #expect(stalled.wait(timeout: .now() + 5) == .success)

    let ranBody = BoolBox()
    let answered = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = pipMainActorSyncBounded(timeout: .milliseconds(50), fallback: true) {
        ranBody.set(true)
        return false
      }
      answered.signal()
    }

    #expect(answered.wait(timeout: .now() + 3) == .success, "the bounded hop never returned")

    // Let the main thread drain, then confirm the abandoned body was skipped.
    released.signal()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { drained.signal() }
    #expect(drained.wait(timeout: .now() + 5) == .success)

    #expect(
      !ranBody.get(),
      "the body ran after the caller had already given up and returned the fallback"
    )
  }
}

/// `Mutex` is non-copyable, so a value shared between two escaping closures
/// needs a reference box.
private final class BoolBox: Sendable {
  private let storage = Mutex(false)
  func set(_ value: Bool) {
    storage.withLock { $0 = value }
  }

  func get() -> Bool {
    storage.withLock { $0 }
  }
}
#endif
