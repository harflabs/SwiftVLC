@testable import SwiftVLC
import Testing

@Suite("PlayerEvent", .tags(.logic))
struct PlayerEventTests {
  @Test("Exhaustive switch over all cases")
  func exhaustiveSwitch() {
    let events: [PlayerEvent] = [
      .stateChanged(.idle),
      .timeChanged(.seconds(1)),
      .positionChanged(0.5),
      .lengthChanged(.seconds(60)),
      .seekableChanged(true),
      .pausableChanged(true),
      .tracksChanged,
      .mediaChanged,
      .encounteredError,
      .volumeChanged(0.5),
      .muted,
      .unmuted,
      .voutChanged(1),
      .bufferingProgress(0.5),
      .chapterChanged(0),
      .recordingChanged(isRecording: true, filePath: "/tmp/out"),
      .titleListChanged,
      .titleSelectionChanged(0),
      .snapshotTaken("/tmp/snap.png"),
      .programAdded(1),
      .programDeleted(1),
      .programSelected(unselectedId: 0, selectedId: 1),
      .programUpdated(1)
    ]
    #expect(events.count == 23)
  }

  @Test("stateChanged associated value extraction")
  func stateChangedExtraction() {
    let event = PlayerEvent.stateChanged(.playing)
    if case .stateChanged(let state) = event {
      #expect(state == .playing)
    } else {
      Issue.record("Expected stateChanged")
    }
  }

  @Test("timeChanged associated value extraction")
  func timeChangedExtraction() {
    let event = PlayerEvent.timeChanged(.seconds(5))
    if case .timeChanged(let time) = event {
      #expect(time == .seconds(5))
    } else {
      Issue.record("Expected timeChanged")
    }
  }

  @Test("positionChanged associated value extraction")
  func positionChangedExtraction() {
    let event = PlayerEvent.positionChanged(0.75)
    if case .positionChanged(let pos) = event {
      #expect(pos == 0.75)
    } else {
      Issue.record("Expected positionChanged")
    }
  }

  @Test("recordingChanged associated value extraction")
  func recordingChangedExtraction() {
    let event = PlayerEvent.recordingChanged(isRecording: true, filePath: "/tmp/out.ts")
    if case .recordingChanged(let isRec, let path) = event {
      #expect(isRec == true)
      #expect(path == "/tmp/out.ts")
    } else {
      Issue.record("Expected recordingChanged")
    }
  }

  @Test("programSelected associated value extraction")
  func programSelectedExtraction() {
    let event = PlayerEvent.programSelected(unselectedId: 0, selectedId: 1)
    if case .programSelected(let unsel, let sel) = event {
      #expect(unsel == 0)
      #expect(sel == 1)
    } else {
      Issue.record("Expected programSelected")
    }
  }

  @Test("Is Sendable")
  func isSendable() {
    let event: PlayerEvent = .muted
    let sendable: any Sendable = event
    _ = sendable
  }
}
