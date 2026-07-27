@testable import SwiftVLC
import Foundation
import Testing

/// Post-`shutdown()` guarantees: one shared teardown, permanent inertness,
/// and immediately-finished streams.
///
/// `shutdown()` promises that on return no libVLC thread owned by the player
/// is still draining and the player is unusable afterwards. Three things have
/// to hold for that to be true for *every* caller rather than just the first:
///
/// 1. Concurrent callers must join the same teardown. Returning early on a
///    flag that the first caller set before suspending hands the second
///    caller a player whose native handle is still being released.
/// 2. Commands issued after shutdown — including from tasks that were
///    already suspended when it began — must not create media or outputs.
/// 3. `events` and `playbackIntentEvents` are computed properties that
///    subscribe per access, so a stream requested after shutdown must arrive
///    already finished rather than waiting forever on a dead source.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerShutdownInertnessTests {
    /// Every concurrent caller must observe the fully torn-down player, not
    /// an intermediate state. The first caller suspends across the offloaded
    /// native teardown, so a caller that returned on the flag alone would run
    /// during that window and see pre-teardown state.
    @Test
    func `Concurrent shutdown callers all join the same teardown`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))

      var callers: [Task<Bool, Never>] = []
      for _ in 0..<8 {
        callers.append(Task { @MainActor in
          await player.shutdown()
          // Both are only published at the very end of the teardown.
          return player.currentMedia == nil && player.state == .idle
        })
      }

      var observed: [Bool] = []
      for caller in callers {
        await observed.append(caller.value)
      }

      #expect(observed.count == 8)
      #expect(
        !observed.contains(false),
        "a concurrent shutdown() caller returned before teardown completed"
      )
    }

    /// Sequential callers must stay idempotent and still join.
    @Test
    func `Repeated shutdown calls remain idempotent`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      await player.shutdown()
      await player.shutdown()
      await player.shutdown()

      #expect(player.currentMedia == nil)
      #expect(player.state == .idle)
    }

    /// A shut-down player must not adopt media: the handle it would attach to
    /// is the inert replacement.
    @Test
    func `load after shutdown does not create media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      await player.shutdown()

      try player.load(Media(url: TestMedia.silenceURL))

      #expect(player.currentMedia == nil, "shut-down player adopted media")
    }

    /// Both playback entry points must reject explicitly rather than
    /// silently driving the inert replacement handle.
    @Test
    func `play after shutdown rejects with an explicit error`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      await player.shutdown()

      #expect(throws: VLCError.self) {
        try player.play()
      }
      #expect(throws: VLCError.self) {
        try player.play(Media(url: TestMedia.silenceURL))
      }
      #expect(player.currentMedia == nil)
      #expect(!player.isPlaying)
    }

    /// A command racing shutdown from an already-suspended task must not
    /// resurrect the player. The command runs after shutdown returns, which
    /// is the suspension point the issue calls out.
    @Test
    func `command resumed after shutdown cannot create media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())

      async let teardown: Void = player.shutdown()
      await teardown

      // Simulates a task that was suspended across the shutdown and only now
      // gets to issue its command.
      await Task.yield()
      try player.load(Media(url: TestMedia.silenceURL))
      #expect(throws: VLCError.self) {
        try player.play()
      }

      #expect(player.currentMedia == nil)
    }

    /// `events` subscribes per access, so a post-shutdown subscriber must get
    /// an already-finished stream. Before terminating the broadcaster this
    /// stream stayed open forever and the iteration below would hang.
    @Test
    func `Event stream requested after shutdown finishes immediately`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      await player.shutdown()

      var received = 0
      for await _ in player.events {
        received += 1
      }
      #expect(received == 0)
    }

    /// Same guarantee for the playback-intent stream.
    @Test
    func `Playback intent stream requested after shutdown finishes immediately`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      await player.shutdown()

      var received = 0
      for await _ in player.playbackIntentEvents {
        received += 1
      }
      #expect(received == 0)
    }

    /// A stream opened *before* shutdown must also finish, so consumers
    /// awaiting it are released rather than stranded.
    @Test
    func `Event stream opened before shutdown finishes on shutdown`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let stream = player.events

      let drained = Task {
        var count = 0
        for await _ in stream {
          count += 1
        }
        return count
      }

      await player.shutdown()
      _ = await drained.value
    }
  }
}
