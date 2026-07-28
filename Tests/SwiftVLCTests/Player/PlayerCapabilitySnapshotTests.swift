@testable import SwiftVLC
import Synchronization
import Testing

/// The snapshot is a `nonisolated` `Mutex` so consumers that cannot hop to the
/// main actor — AVKit's synchronous PiP queries, most of all — can read it.
/// That makes the atomicity of each publish a real contract rather than an
/// incidental property of the current call sites.
@Suite(.tags(.logic, .mainActor))
@MainActor struct PlayerCapabilitySnapshotTests {
  @Test
  func `Publishing mirrors duration and seekability`() {
    let player = Player(instance: TestInstance.shared)

    player._setStateForTesting(duration: .seconds(120), isSeekable: true)

    let snapshot = player.capabilitySnapshot.withLock { $0 }
    #expect(snapshot.durationMilliseconds == 120_000)
    #expect(snapshot.isSeekable)
    #expect(!snapshot.isReset)
  }

  /// The invariant ``PlayerCapabilitySnapshot/isReset`` exists to prove: a
  /// reader seeing the new generation must see the conservative values with it.
  @Test
  func `A media reset publishes the new generation with reset values`() {
    let player = Player(instance: TestInstance.shared)

    player._setStateForTesting(duration: .seconds(120), isSeekable: true)
    let before = player.capabilitySnapshot.withLock { $0 }

    player.resetMediaDerivedState()

    let after = player.capabilitySnapshot.withLock { $0 }
    #expect(after.generation == before.generation &+ 1)
    #expect(after.durationMilliseconds == nil)
    #expect(after.isSeekable == false)
    #expect(after.isReset)
  }

  /// `duration` and `isSeekable` publish from their own `didSet`, so clearing
  /// them one at a time would otherwise expose "this media's duration beside
  /// the previous one's seekability". A PiP observer that sampled such a
  /// snapshot right after a media change would find `isReset` false, conclude
  /// `Player` had not yet processed the change, and distrust the polled
  /// capability for the rest of that media — leaving finite seekable VOD
  /// pinned to linear playback with no skip controls, which is the very
  /// regression this snapshot was introduced to fix.
  @Test
  func `A partial capability change does not reach readers`() {
    let player = Player(instance: TestInstance.shared)

    player._setStateForTesting(duration: .seconds(120), isSeekable: true)

    player.isSuppressingCapabilityPublish = true
    player.duration = nil
    defer { player.isSuppressingCapabilityPublish = false }

    let midChange = player.capabilitySnapshot.withLock { $0 }
    #expect(
      midChange.durationMilliseconds == 120_000,
      "a half-applied capability change was published"
    )
    #expect(midChange.isSeekable)
  }

  /// Suppression must not swallow the change permanently: the reset publishes
  /// the whole new state in one lock acquisition once the flag clears.
  @Test
  func `Publishing resumes once suppression clears`() {
    let player = Player(instance: TestInstance.shared)

    player.isSuppressingCapabilityPublish = true
    player._setStateForTesting(duration: .seconds(90), isSeekable: true)
    #expect(player.capabilitySnapshot.withLock { $0 }.isReset)

    player.isSuppressingCapabilityPublish = false
    player.publishCapabilitySnapshot()

    let snapshot = player.capabilitySnapshot.withLock { $0 }
    #expect(snapshot.durationMilliseconds == 90000)
    #expect(snapshot.isSeekable)
  }
}
