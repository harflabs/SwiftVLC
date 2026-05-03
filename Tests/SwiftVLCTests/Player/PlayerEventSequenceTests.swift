@testable import SwiftVLC
import Foundation
import Testing

/// Locks down the order of state-machine events `Player` emits during
/// playback of fixture media. A libVLC version bump that changes the
/// event order surfaces immediately as a snapshot diff with the
/// current vs. expected sequence rendered side-by-side.
///
/// **What's snapshotted:** stable lifecycle events only —
/// `mediaChanged`, `stateChanged(_)`, `tracksChanged`, `lengthChanged(_)`,
/// `seekableChanged(_)`, `pausableChanged(_)`, `mediaStopping`,
/// `encounteredError`. Timing-sensitive events (`timeChanged`,
/// `positionChanged`, `bufferingProgress`, `voutChanged`,
/// `volumeChanged`) are filtered out — they fire at unpredictable
/// rates depending on system load and would make the snapshots
/// flaky.
///
/// **Updates:** if a libVLC version bump changes the expected order,
/// fix the inline string literal manually. No record-mode auto-update —
/// snapshots stay audited by humans.
extension Integration {
  @Suite(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia))
  @MainActor struct PlayerEventSequenceTests {
    /// Audio-only WAV: should emit a deterministic open → playing →
    /// stopping → stopped lifecycle. No video tracks to discover, so
    /// `tracksChanged` only fires for the single audio ES.
    @Test
    func `silence wav lifecycle event sequence`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let events = collectStableLifecycleEvents(
        player: player,
        until: { events in events.contains("stateChanged(stopped)") },
        timeout: .seconds(5)
      )

      try player.play(url: TestMedia.silenceURL)
      let actual = try await events.value

      // Expected sequence pinned 2026-05-03 against libVLC 4.0
      // (xcframework checksum in Package.swift). Notes:
      // - `programAdded`/`programSelected`/`programUpdated` fire because
      //   libVLC always emits at least one program (id=0) for any
      //   container — even WAV — during demuxer init.
      // - `tracksChanged` is filtered out (see `stableLifecycleDescription`)
      //   because under load the count varies depending on ES discovery
      //   timing.
      // - `seekableChanged(false)`/`pausableChanged(false)` near the end
      //   come from the player tearing down before sending `mediaStopping`.
      let expected = """
      mediaChanged
      stateChanged(opening)
      programAdded(0)
      programSelected(unselectedId: -1, selectedId: 0)
      programUpdated(0)
      seekableChanged(true)
      pausableChanged(true)
      lengthChanged(0:00)
      stateChanged(playing)
      seekableChanged(false)
      pausableChanged(false)
      mediaStopping
      stateChanged(stopping)
      programDeleted(0)
      stateChanged(stopped)
      """

      expectStringMatch(
        actual,
        expected,
        "silence.wav lifecycle drifted from the pinned libVLC behavior"
      )
    }

    /// Video MP4 with metadata: same lifecycle shape as audio, plus
    /// an extra `tracksChanged` firing after `playing` because the
    /// video ES is selected at that point.
    @Test
    func `mp4 lifecycle event sequence`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let events = collectStableLifecycleEvents(
        player: player,
        until: { events in events.contains("stateChanged(stopped)") },
        timeout: .seconds(5)
      )

      try player.play(url: TestMedia.testMP4URL)
      let actual = try await events.value

      let expected = """
      mediaChanged
      stateChanged(opening)
      programAdded(0)
      programSelected(unselectedId: -1, selectedId: 0)
      programUpdated(0)
      seekableChanged(true)
      pausableChanged(true)
      lengthChanged(0:01)
      stateChanged(playing)
      seekableChanged(false)
      pausableChanged(false)
      mediaStopping
      stateChanged(stopping)
      programDeleted(0)
      stateChanged(stopped)
      """

      expectStringMatch(
        actual,
        expected,
        "test.mp4 lifecycle drifted from the pinned libVLC behavior"
      )
    }

    /// 2-second video: same shape as test.mp4, longer length — verifies
    /// `lengthChanged` reports the actual media duration.
    @Test
    func `twosec mp4 lifecycle event sequence`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let events = collectStableLifecycleEvents(
        player: player,
        until: { events in events.contains("stateChanged(stopped)") },
        timeout: .seconds(8)
      )

      try player.play(url: TestMedia.twosecURL)
      let actual = try await events.value

      let expected = """
      mediaChanged
      stateChanged(opening)
      programAdded(0)
      programSelected(unselectedId: -1, selectedId: 0)
      programUpdated(0)
      seekableChanged(true)
      pausableChanged(true)
      lengthChanged(0:02)
      stateChanged(playing)
      seekableChanged(false)
      pausableChanged(false)
      mediaStopping
      stateChanged(stopping)
      programDeleted(0)
      stateChanged(stopped)
      """

      expectStringMatch(
        actual,
        expected,
        "twosec.mp4 lifecycle drifted from the pinned libVLC behavior"
      )
    }
  }
}

// MARK: - Helpers

/// Collects only the lifecycle-relevant events from `player.events` —
/// dropping the high-frequency timing events that would make snapshots
/// flaky. Adjacent identical events are coalesced (`tracksChanged` can
/// fire many times during ES discovery; collapsing keeps snapshots
/// stable).
private func collectStableLifecycleEvents(
  player: Player,
  until predicate: @escaping @Sendable ([String]) -> Bool,
  timeout: Duration
) -> Task<String, Error> {
  let stream = player.events
  return Task.detached { @Sendable in
    try await withThrowingTaskGroup(of: String?.self) { group in
      group.addTask {
        var collected: [String] = []
        for await event in stream {
          guard let line = stableLifecycleDescription(of: event) else { continue }
          if collected.last != line {
            collected.append(line)
          }
          if predicate(collected) { break }
        }
        return collected.joined(separator: "\n")
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return nil
      }
      defer { group.cancelAll() }
      guard let result = try await group.next(), let result else {
        throw EventCollectionTimeout()
      }
      return result
    }
  }
}

private struct EventCollectionTimeout: Error, CustomStringConvertible {
  var description: String {
    "timed out collecting stable lifecycle events"
  }
}

/// Maps a `PlayerEvent` to a snapshot-stable string, or `nil` to skip
/// it from the snapshot.
///
/// Filtered out:
/// - `timeChanged`, `positionChanged`, `bufferingProgress`,
///   `voutChanged`, `volumeChanged`: fire at unpredictable frequencies.
/// - `tracksChanged`: fires once per ES add/remove/select; under load
///   the count varies (initial discovery may be split across multiple
///   firings). Dropping it from snapshots leaves the LIFECYCLE STATES
///   (state changes, length/seek/pause flags, programs, mediaStopping)
///   as the stable signal.
private func stableLifecycleDescription(of event: PlayerEvent) -> String? {
  switch event {
  case .timeChanged, .positionChanged, .bufferingProgress, .voutChanged,
       .volumeChanged, .tracksChanged:
    nil
  default:
    event.description
  }
}
