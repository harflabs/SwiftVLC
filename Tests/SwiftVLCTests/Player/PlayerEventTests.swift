@testable import SwiftVLC
import Testing

@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct PlayerEventTests {
  @Test
  func `Exhaustive switch over all cases`() {
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
      .corked,
      .uncorked,
      .audioDeviceChanged("default"),
      .voutChanged(1),
      .bufferingProgress(0.5),
      .chapterChanged(0),
      .recordingChanged(isRecording: true, filePath: "/tmp/out"),
      .titleListChanged,
      .titleSelectionChanged(0),
      .snapshotTaken("/tmp/snap.png"),
      .mediaStopping,
      .programAdded(1),
      .programDeleted(1),
      .programSelected(unselectedId: 0, selectedId: 1),
      .programUpdated(1)
    ]
    #expect(events.count == 27)
  }

  @Test
  func `audioDeviceChanged associated value extraction`() {
    let event = PlayerEvent.audioDeviceChanged("builtin")
    if case .audioDeviceChanged(let device) = event {
      #expect(device == "builtin")
    } else {
      Issue.record("Expected audioDeviceChanged")
    }

    let nilEvent = PlayerEvent.audioDeviceChanged(nil)
    if case .audioDeviceChanged(let device) = nilEvent {
      #expect(device == nil)
    } else {
      Issue.record("Expected audioDeviceChanged")
    }
  }

  @Test
  func `stateChanged associated value extraction`() {
    let event = PlayerEvent.stateChanged(.playing)
    if case .stateChanged(let state) = event {
      #expect(state == .playing)
    } else {
      Issue.record("Expected stateChanged")
    }
  }

  @Test
  func `timeChanged associated value extraction`() {
    let event = PlayerEvent.timeChanged(.seconds(5))
    if case .timeChanged(let time) = event {
      #expect(time == .seconds(5))
    } else {
      Issue.record("Expected timeChanged")
    }
  }

  @Test
  func `positionChanged associated value extraction`() {
    let event = PlayerEvent.positionChanged(0.75)
    if case .positionChanged(let pos) = event {
      #expect(pos == 0.75)
    } else {
      Issue.record("Expected positionChanged")
    }
  }

  @Test
  func `recordingChanged associated value extraction`() {
    let event = PlayerEvent.recordingChanged(isRecording: true, filePath: "/tmp/out.ts")
    if case .recordingChanged(let isRec, let path) = event {
      #expect(isRec == true)
      #expect(path == "/tmp/out.ts")
    } else {
      Issue.record("Expected recordingChanged")
    }
  }

  @Test
  func `programSelected associated value extraction`() {
    let event = PlayerEvent.programSelected(unselectedId: 0, selectedId: 1)
    if case .programSelected(let unsel, let sel) = event {
      #expect(unsel == 0)
      #expect(sel == 1)
    } else {
      Issue.record("Expected programSelected")
    }
  }

  @Test
  func `Is Sendable`() {
    let event: PlayerEvent = .muted
    let sendable: any Sendable = event
    _ = sendable
  }
}
