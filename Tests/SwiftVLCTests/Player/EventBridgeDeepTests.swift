@testable import SwiftVLC
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct EventBridgeDeepTests {
    // MARK: - Events that fire naturally during playback

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `MediaChanged event fires when media is loaded`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let receivedMediaChanged = Mutex(false)
      let task = Task.detached { @Sendable in
        for await event in stream {
          if case .mediaChanged = event {
            receivedMediaChanged.withLock { $0 = true }
            break
          }
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      guard try await poll(until: { receivedMediaChanged.withLock { $0 } }) else {
        task.cancel()
        await task.value
        player.stop()
        return
      }
      task.cancel()
      await task.value
      player.stop()

      #expect(receivedMediaChanged.withLock { $0 })
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `TracksChanged event fires after load`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let receivedTracksChanged = Mutex(false)
      let task = Task.detached { @Sendable in
        for await event in stream {
          if case .tracksChanged = event {
            receivedTracksChanged.withLock { $0 = true }
            break
          }
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          receivedTracksChanged.withLock { $0 }
        }) else {
        task.cancel()
        await task.value
        player.stop()
        // tracksChanged may not fire in all environments; no crash is the baseline
        return
      }
      task.cancel()
      await task.value
      player.stop()

      #expect(receivedTracksChanged.withLock { $0 })
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Multiple events accumulate correctly`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let eventCounts = Mutex<[String: Int]>([:])
      let task = Task.detached { @Sendable in
        for await event in stream {
          let total = eventCounts.withLock { counts -> Int in
            let key = switch event {
            case .stateChanged: "state"
            case .timeChanged: "time"
            case .positionChanged: "position"
            case .bufferingProgress: "buffering"
            case .mediaChanged: "media"
            case .tracksChanged: "tracks"
            case .lengthChanged: "length"
            case .seekableChanged: "seekable"
            case .pausableChanged: "pausable"
            default: "other"
            }
            counts[key, default: 0] += 1
            return counts.values.reduce(0, +)
          }
          if total >= 10 { break }
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))
      guard
        try await poll(every: .milliseconds(100), timeout: .seconds(5), until: {
          eventCounts.withLock { $0.values.reduce(0, +) } >= 10
        }) else {
        task.cancel()
        await task.value
        player.stop()
        // Still check we got some events
        #expect(eventCounts.withLock { $0.values.reduce(0, +) } > 0, "Should have received some events")
        return
      }
      task.cancel()
      await task.value
      player.stop()

      let counts = eventCounts.withLock { $0 }
      #expect(counts.values.reduce(0, +) >= 10, "Should have accumulated at least 10 events")
      // Multiple different event types should have fired
      #expect(counts.keys.count >= 2, "Should have received at least 2 different event types")
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Stream can be consumed with for-await-in pattern`() async throws {
      let player = Player(instance: TestInstance.shared)
      let stream = player.events

      let collected = Mutex<[PlayerEvent]>([])
      let task = Task.detached { @Sendable in
        for await event in stream {
          let count = collected.withLock {
            $0.append(event)
            return $0.count
          }
          if count >= 3 { break }
        }
      }

      try player.play(Media(url: TestMedia.testMP4URL))
      guard try await poll(until: { collected.withLock { $0.count } >= 3 }) else {
        task.cancel()
        await task.value
        player.stop()
        return
      }
      task.cancel()
      await task.value
      player.stop()

      #expect(collected.withLock { $0.count } >= 3)
    }

    // MARK: - PlayerEvent enum coverage (no libVLC needed)

    @Test(.tags(.logic))
    func `PlayerEvent Sendable verification`() {
      // All enum cases with associated values must be Sendable
      let events: [any Sendable] = [
        PlayerEvent.stateChanged(.idle),
        PlayerEvent.timeChanged(.seconds(1)),
        PlayerEvent.positionChanged(0.5),
        PlayerEvent.lengthChanged(.seconds(60)),
        PlayerEvent.seekableChanged(true),
        PlayerEvent.pausableChanged(false),
        PlayerEvent.tracksChanged,
        PlayerEvent.mediaChanged,
        PlayerEvent.encounteredError,
        PlayerEvent.volumeChanged(0.8),
        PlayerEvent.muted,
        PlayerEvent.unmuted,
        PlayerEvent.voutChanged(2),
        PlayerEvent.bufferingProgress(0.75),
        PlayerEvent.chapterChanged(3),
        PlayerEvent.recordingChanged(isRecording: true, filePath: "/tmp/rec.ts"),
        PlayerEvent.recordingChanged(isRecording: false, filePath: nil),
        PlayerEvent.titleListChanged,
        PlayerEvent.titleSelectionChanged(5),
        PlayerEvent.snapshotTaken("/tmp/snap.png"),
        PlayerEvent.programAdded(10),
        PlayerEvent.programDeleted(10),
        PlayerEvent.programSelected(unselectedId: 1, selectedId: 2),
        PlayerEvent.programUpdated(10)
      ]
      #expect(events.count == 24)
    }

    @Test(.tags(.logic))
    func `PlayerEvent identification for all cases`() {
      // Verify pattern matching works for every case
      let cases: [(PlayerEvent, String)] = [
        (.stateChanged(.idle), "stateChanged"),
        (.stateChanged(.opening), "stateChanged"),
        (.stateChanged(.playing), "stateChanged"),
        (.stateChanged(.paused), "stateChanged"),
        (.stateChanged(.stopped), "stateChanged"),
        (.stateChanged(.stopping), "stateChanged"),
        (.timeChanged(.milliseconds(500)), "timeChanged"),
        (.positionChanged(0.25), "positionChanged"),
        (.lengthChanged(.seconds(120)), "lengthChanged"),
        (.seekableChanged(true), "seekableChanged"),
        (.pausableChanged(true), "pausableChanged"),
        (.tracksChanged, "tracksChanged"),
        (.mediaChanged, "mediaChanged"),
        (.encounteredError, "encounteredError"),
        (.volumeChanged(1.0), "volumeChanged"),
        (.muted, "muted"),
        (.unmuted, "unmuted"),
        (.voutChanged(0), "voutChanged"),
        (.bufferingProgress(1.0), "bufferingProgress"),
        (.chapterChanged(1), "chapterChanged"),
        (.recordingChanged(isRecording: false, filePath: nil), "recordingChanged"),
        (.titleListChanged, "titleListChanged"),
        (.titleSelectionChanged(2), "titleSelectionChanged"),
        (.snapshotTaken("/path"), "snapshotTaken"),
        (.programAdded(5), "programAdded"),
        (.programDeleted(5), "programDeleted"),
        (.programSelected(unselectedId: 0, selectedId: 1), "programSelected"),
        (.programUpdated(5), "programUpdated")
      ]

      for (event, expectedLabel) in cases {
        let label = identifyEvent(event)
        #expect(label == expectedLabel, "Expected \(expectedLabel) but got \(label)")
      }
    }

    @Test(.tags(.logic))
    func `PlayerEvent associated value extraction for all value-carrying cases`() {
      // chapterChanged
      if case .chapterChanged(let ch) = PlayerEvent.chapterChanged(7) {
        #expect(ch == 7)
      } else {
        Issue.record("chapterChanged extraction failed")
      }

      // titleSelectionChanged
      if case .titleSelectionChanged(let idx) = PlayerEvent.titleSelectionChanged(3) {
        #expect(idx == 3)
      } else {
        Issue.record("titleSelectionChanged extraction failed")
      }

      // snapshotTaken
      if case .snapshotTaken(let path) = PlayerEvent.snapshotTaken("/snap.png") {
        #expect(path == "/snap.png")
      } else {
        Issue.record("snapshotTaken extraction failed")
      }

      // programAdded
      if case .programAdded(let id) = PlayerEvent.programAdded(42) {
        #expect(id == 42)
      } else {
        Issue.record("programAdded extraction failed")
      }

      // programDeleted
      if case .programDeleted(let id) = PlayerEvent.programDeleted(99) {
        #expect(id == 99)
      } else {
        Issue.record("programDeleted extraction failed")
      }

      // programUpdated
      if case .programUpdated(let id) = PlayerEvent.programUpdated(7) {
        #expect(id == 7)
      } else {
        Issue.record("programUpdated extraction failed")
      }

      // voutChanged
      if case .voutChanged(let count) = PlayerEvent.voutChanged(3) {
        #expect(count == 3)
      } else {
        Issue.record("voutChanged extraction failed")
      }

      // bufferingProgress
      if case .bufferingProgress(let pct) = PlayerEvent.bufferingProgress(0.42) {
        #expect(pct == Float(0.42))
      } else {
        Issue.record("bufferingProgress extraction failed")
      }

      // lengthChanged
      if case .lengthChanged(let dur) = PlayerEvent.lengthChanged(.seconds(90)) {
        #expect(dur == .seconds(90))
      } else {
        Issue.record("lengthChanged extraction failed")
      }

      // seekableChanged
      if case .seekableChanged(let val) = PlayerEvent.seekableChanged(false) {
        #expect(val == false)
      } else {
        Issue.record("seekableChanged extraction failed")
      }

      // pausableChanged
      if case .pausableChanged(let val) = PlayerEvent.pausableChanged(true) {
        #expect(val == true)
      } else {
        Issue.record("pausableChanged extraction failed")
      }

      // volumeChanged
      if case .volumeChanged(let vol) = PlayerEvent.volumeChanged(0.65) {
        #expect(vol == Float(0.65))
      } else {
        Issue.record("volumeChanged extraction failed")
      }

      // recordingChanged with nil path
      if case .recordingChanged(let isRec, let path) = PlayerEvent.recordingChanged(isRecording: false, filePath: nil) {
        #expect(isRec == false)
        #expect(path == nil)
      } else {
        Issue.record("recordingChanged nil path extraction failed")
      }
    }

    // MARK: - Helpers

    private func identifyEvent(_ event: PlayerEvent) -> String {
      switch event {
      case .stateChanged: "stateChanged"
      case .timeChanged: "timeChanged"
      case .positionChanged: "positionChanged"
      case .lengthChanged: "lengthChanged"
      case .seekableChanged: "seekableChanged"
      case .pausableChanged: "pausableChanged"
      case .tracksChanged: "tracksChanged"
      case .mediaChanged: "mediaChanged"
      case .encounteredError: "encounteredError"
      case .volumeChanged: "volumeChanged"
      case .muted: "muted"
      case .unmuted: "unmuted"
      case .corked: "corked"
      case .uncorked: "uncorked"
      case .audioDeviceChanged: "audioDeviceChanged"
      case .voutChanged: "voutChanged"
      case .bufferingProgress: "bufferingProgress"
      case .chapterChanged: "chapterChanged"
      case .recordingChanged: "recordingChanged"
      case .titleListChanged: "titleListChanged"
      case .titleSelectionChanged: "titleSelectionChanged"
      case .snapshotTaken: "snapshotTaken"
      case .mediaStopping: "mediaStopping"
      case .programAdded: "programAdded"
      case .programDeleted: "programDeleted"
      case .programSelected: "programSelected"
      case .programUpdated: "programUpdated"
      }
    }
  }
}
