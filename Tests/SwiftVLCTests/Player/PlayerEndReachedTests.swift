@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// Indices of `.endReached` deliveries in a collected raw sequence.
private func endReachedIndices(in events: [PlayerEvent]) -> [Int] {
  events.indices.filter { index in
    if case .endReached = events[index] {
      true
    } else {
      false
    }
  }
}

/// Index of the first `.stateChanged(.stopped)` in a collected raw sequence.
private func firstStoppedIndex(in events: [PlayerEvent]) -> Int? {
  events.firstIndex { event in
    if case .stateChanged(.stopped) = event {
      true
    } else {
      false
    }
  }
}

/// End-of-media synthesis: libVLC 4 collapses natural end and requested
/// stop into the same `Stopped` event, so the player synthesizes
/// ``PlayerEvent/endReached`` only for a `stopped` with no recorded cause
/// (library stop, decode error, attached list player). Every test drives
/// real playback to (or away from) a natural end, so the whole suite is
/// gated on `TestCondition.canPlayMedia`.
extension Integration {
  @Suite(.tags(.mainActor, .async), .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"))
  @MainActor struct PlayerEndReachedTests {
    /// Natural end of the 1s fixture: exactly one `.endReached`, ordered
    /// after `.stateChanged(.stopped)` in the raw sequence, and a
    /// parallel sourced subscription sees both carrying the same source.
    @Test(.timeLimit(.minutes(1)))
    func `Natural end emits exactly one endReached after stopped with the same source`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)
      let sourcedStream = player.eventBridge.makeSourcedStream(policy: .unbounded)

      let collected = Mutex<[PlayerEvent]>([])
      let collector = Task.detached { @Sendable in
        for await event in stream {
          collected.withLock { $0.append(event) }
        }
      }
      let stoppedSource = Mutex<UInt?>(nil)
      let endSource = Mutex<UInt?>(nil)
      let sourcedCollector = Task.detached { @Sendable in
        for await sourced in sourcedStream {
          switch sourced.event {
          case .stateChanged(.stopped):
            stoppedSource.withLock { $0 = sourced.source }
          case .endReached:
            endSource.withLock { $0 = sourced.source }
          default:
            continue
          }
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after the 1s fixture plays out"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()
      sourcedCollector.cancel()

      #expect(player.didReachEnd)
      let snapshot = collected.withLock { $0 }
      let endIndices = endReachedIndices(in: snapshot)
      #expect(endIndices.count == 1, "expected exactly one endReached: \(snapshot)")
      let endIndex = try #require(endIndices.first)
      let stoppedIndex = try #require(
        firstStoppedIndex(in: snapshot),
        "no stateChanged(stopped) in the collected sequence: \(snapshot)"
      )
      #expect(stoppedIndex < endIndex, "endReached did not follow stopped: \(snapshot)")

      let stopped = try #require(stoppedSource.withLock { $0 }, "sourced stream never saw stopped")
      let end = try #require(endSource.withLock { $0 }, "sourced stream never saw endReached")
      #expect(stopped == end, "stopped and endReached carried different sources")
    }

    @Test(.timeLimit(.minutes(1)))
    func `Explicit stop mid-playback synthesizes no endReached`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let sawEnd = Mutex(false)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            sawEnd.withLock { $0 = true }
          }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      player.stop()
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(!sawEnd.withLock { $0 }, "explicit stop() read as a natural end")
      #expect(!player.didReachEnd)
    }

    /// A consumed stop flag must not bleed into the next session: after
    /// stop() and its `stopped`, a fresh load + play to natural end has
    /// to synthesize its own single `.endReached`.
    @Test(.timeLimit(.minutes(1)))
    func `Stop flag is consumed and the next natural end still synthesizes`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      player.stop()
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped after explicit stop"
      )

      let media = try Media(url: TestMedia.testMP4URL)
      player.load(media)
      try player.play()
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after the second session plays out"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "stale stop flag swallowed or duplicated the natural end")
    }

    /// An input error latches for the session: the `stopped` that follows
    /// `.encounteredError` must not read as a natural end. The fixture is
    /// a nonexistent path — byte-garbage files are no use here, libVLC 4's
    /// demux fallback plays them as a raw ES stream to a *genuine* natural
    /// end, while a missing file deterministically fails to open and emits
    /// `.encounteredError` before its `stopped`.
    @Test(.timeLimit(.minutes(1)))
    func `Error session never synthesizes endReached`() async throws {
      let missingPath = "/nonexistent/swiftvlc-\(UUID().uuidString).mp4"

      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let sawError = Mutex(false)
      let sawEnd = Mutex(false)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          switch event {
          case .encounteredError:
            sawError.withLock { $0 = true }
          case .endReached:
            sawEnd.withLock { $0 = true }
          default:
            continue
          }
        }
      }

      try player.play(Media(path: missingPath))
      try #require(
        await poll(timeout: .seconds(10), until: {
          sawError.withLock { $0 } || player.state == .error
        }),
        "Waiting for: encounteredError from the unopenable media"
      )
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped after the error"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(!sawEnd.withLock { $0 }, "error session read as a natural end")
      #expect(!player.didReachEnd)
    }

    /// Stalls an `.unbounded` consumer across the whole session so the
    /// backlog grows past the default 64-element buffer; the drained
    /// backlog must still contain `.stateChanged(.stopped)` followed by
    /// `.endReached` — a lossy buffer would evict the one-shot pair.
    @Test(.timeLimit(.minutes(1)))
    func `Stalled unbounded consumer drains stopped then endReached from the backlog`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let stallReleased = Mutex(false)
      let collected = Mutex<[PlayerEvent]>([])
      let collector = Task.detached { @Sendable in
        while !stallReleased.withLock({ $0 }) {
          try? await Task.sleep(for: .milliseconds(10))
        }
        for await event in stream {
          collected.withLock { $0.append(event) }
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(until: { player.currentTime > .zero }),
        "Waiting for: currentTime advancing while the consumer is stalled"
      )
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd while the consumer is stalled"
      )

      stallReleased.withLock { $0 = true }
      try #require(
        await poll(timeout: .seconds(5), until: {
          collected.withLock { !endReachedIndices(in: $0).isEmpty }
        }),
        "Waiting for: endReached delivered from the drained backlog"
      )
      collector.cancel()

      let snapshot = collected.withLock { $0 }
      let endIndex = try #require(endReachedIndices(in: snapshot).first)
      let stoppedIndex = try #require(
        firstStoppedIndex(in: snapshot),
        "stopped missing from the drained backlog: \(snapshot)"
      )
      #expect(stoppedIndex < endIndex, "backlog lost the stopped-before-endReached ordering: \(snapshot)")
    }

    /// While a `MediaListPlayer` drives the handle, list stops must not
    /// synthesize `.endReached`; detaching clears the suppression so a
    /// direct play to natural end synthesizes again.
    @Test(.timeLimit(.minutes(1)))
    func `List player stop is suppressed and detach restores synthesis`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()
      try #require(
        await poll(until: { listPlayer.isPlaying }),
        "Waiting for: listPlayer.isPlaying"
      )
      listPlayer.stop()
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped after listPlayer.stop()"
      )
      try await Task.sleep(for: .milliseconds(300))
      #expect(endCount.withLock { $0 } == 0, "list-player stop synthesized endReached")

      listPlayer.mediaPlayer = nil
      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after detaching the list player"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "detach did not restore end synthesis")
    }

    /// `stop()` on an idle player issues no native stop, so no flag may
    /// go stale and swallow the next genuine natural end.
    @Test(.timeLimit(.minutes(1)))
    func `Stop while idle does not suppress the next natural end`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      player.stop()
      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after stop-while-idle"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "idle stop left a stale flag or duplicated the end")
    }

    /// stop() immediately followed by load(): the in-flight `Stopped`
    /// from media A must be consumed by the pending stop flag, not
    /// misread as media B's natural end; B's real end then synthesizes
    /// exactly once.
    @Test(.timeLimit(.minutes(1)))
    func `Stop-then-load race neither fakes nor swallows the end`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      let mediaB = try Media(url: TestMedia.testMP4URL)
      player.stop()
      player.load(mediaB)
      try await Task.sleep(for: .milliseconds(500))
      #expect(endCount.withLock { $0 } == 0, "in-flight Stopped read as a phantom natural end")
      #expect(!player.didReachEnd)

      try player.play()
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after media B plays out"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "stop-then-load race swallowed or duplicated the end")
    }

    /// `load()` while playing — no `stop()` in between. Setting media on
    /// a started handle stops the in-flight input, and that `Stopped` is
    /// library-initiated: it must not read as a natural end of the
    /// interrupted media. The replacement media's real end then
    /// synthesizes exactly once.
    @Test(.timeLimit(.minutes(1)))
    func `Load while playing does not synthesize an end`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      let mediaB = try Media(url: TestMedia.testMP4URL)
      player.load(mediaB)
      try await Task.sleep(for: .milliseconds(500))
      #expect(endCount.withLock { $0 } == 0, "load-while-playing's Stopped read as a phantom natural end")
      #expect(!player.didReachEnd)

      try player.play()
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after the replacement media plays out"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "load-while-playing swallowed or duplicated the end")
    }

    /// Detaching a `MediaListPlayer` mid-playback: the native rebuild
    /// stops the still-bound handle *after* suppression is lifted, so
    /// that deferred `Stopped` must be recorded as library-initiated or
    /// it reads as a natural end of the item the user detached. A direct
    /// play to natural end afterwards synthesizes exactly once.
    @Test(.timeLimit(.minutes(1)))
    func `Detach while playing does not synthesize an end`() async throws {
      let instance = TestInstance.makePlayback()
      let listPlayer = MediaListPlayer(instance: instance)
      let player = Player(instance: instance)
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      listPlayer.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer.mediaList = list
      listPlayer.play()
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing under the list player"
      )

      listPlayer.mediaPlayer = nil
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped after the detach's deferred native stop"
      )
      try await Task.sleep(for: .milliseconds(700))
      #expect(endCount.withLock { $0 } == 0, "mid-playback detach's Stopped read as a natural end")
      #expect(!player.didReachEnd)

      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after the direct play"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "detach-while-playing swallowed or duplicated the end")
    }

    /// Dropping a still-attached `MediaListPlayer` without ever setting
    /// `mediaPlayer = nil`: its deinit must lift suppression, or the
    /// player never synthesizes a natural end again — the weak
    /// back-reference nils silently and nothing else clears the flag.
    @Test(.timeLimit(.minutes(1)))
    func `List player deinit lifts suppression`() async throws {
      let instance = TestInstance.makePlayback()
      let player = Player(instance: instance)
      let stream = player.events(policy: .unbounded, filter: nil)

      let endCount = Mutex(0)
      let collector = Task.detached { @Sendable in
        for await event in stream {
          if case .endReached = event {
            endCount.withLock { $0 += 1 }
          }
        }
      }

      var listPlayer: MediaListPlayer? = MediaListPlayer(instance: instance)
      listPlayer?.mediaPlayer = player
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      listPlayer?.mediaList = list
      listPlayer?.play()
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing under the list player"
      )
      listPlayer?.stop()
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped after listPlayer.stop()"
      )

      listPlayer = nil
      // Deinit offloads a final native stop+release of the still-bound
      // list-player handle to a background queue; let it land against
      // the already-stopped player before driving the handle directly,
      // or it can cut the new session short.
      try await Task.sleep(for: .milliseconds(300))
      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(timeout: .seconds(15), until: { player.didReachEnd }),
        "Waiting for: didReachEnd after the list player deinit"
      )
      try await Task.sleep(for: .milliseconds(300))
      collector.cancel()

      #expect(endCount.withLock { $0 } == 1, "deinit left suppression latched or duplicated the end")
    }
  }
}
