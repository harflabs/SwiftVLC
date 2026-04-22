@testable import SwiftVLC
import Testing

/// Fails the current test if `player` does not reach `state` before
/// `timeout`. Subscribes to the event stream synchronously before the
/// caller's action is taken, so there's no race between subscription
/// and the first event.
///
/// Replaces the silent-bailout pattern
/// `guard try await poll(...) else { player.stop(); return }`, which
/// passed the test on timeout — hiding real regressions. With this
/// helper a stuck player surfaces a test failure instead of a green
/// check.
///
/// ```swift
/// let playing = subscribeAndAwait(.playing, on: player)
/// try player.play(url: ...)
/// try await requireReached(playing, "Playback never started")
/// ```
func requireReached(
  _ task: Task<Bool, Never>,
  _ comment: Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
)
  async throws {
  let reached = await task.value
  try #require(reached, comment, sourceLocation: sourceLocation)
}

/// Subscribes to `player.events` *before* returning, so a caller can
/// kick off an action (e.g. `player.play(...)`) without racing the
/// subscription against the first event. The returned future resolves
/// when a matching `.stateChanged` event is seen or `timeout` elapses.
///
/// Subscribing from a detached task means event delivery bypasses
/// MainActor entirely — events arrive straight from the libVLC thread
/// via `AsyncStream.Continuation.yield` without having to wait for the
/// main actor to become available.
///
/// Usage:
/// ```swift
/// let playing = subscribeAndAwait(.playing, on: player)
/// try player.play(...)
/// try #require(await playing.value)
/// ```
///
/// - Returns: A `Task` whose `.value` is `true` when a matching event
///   arrives before the timeout, `false` if the stream ended or the
///   timeout elapsed first.
func subscribeAndAwait(
  _ state: PlayerState,
  on player: Player,
  timeout: Duration = .seconds(5)
) -> Task<Bool, Never> {
  let stream = player.events
  return Task.detached { @Sendable in
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await event in stream {
          if case .stateChanged(let s) = event, s == state { return true }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }
}

/// VLC emits either `.stopping` or `.stopped` as the terminal state
/// depending on build / media type, so any `.stop()`-triggered
/// assertion needs to accept either.
func subscribeAndAwaitTerminalStop(
  on player: Player,
  timeout: Duration = .seconds(5)
) -> Task<Bool, Never> {
  let stream = player.events
  return Task.detached { @Sendable in
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await event in stream {
          if case .stateChanged(let s) = event, s == .stopped || s == .stopping {
            return true
          }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }
}
