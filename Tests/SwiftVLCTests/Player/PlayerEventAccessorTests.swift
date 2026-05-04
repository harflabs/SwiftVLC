@testable import SwiftVLC
import CustomDump
import Testing

extension Logic {
  struct PlayerEventAccessorTests {
    @Test
    func `Per-case accessors return associated payloads`() throws {
      expectNoDifference(PlayerEvent.stateChanged(.playing).stateChanged, .playing)
      expectNoDifference(PlayerEvent.timeChanged(.seconds(5)).timeChanged, .seconds(5))
      expectNoDifference(PlayerEvent.positionChanged(0.25).positionChanged, 0.25)
      expectNoDifference(PlayerEvent.lengthChanged(.seconds(90)).lengthChanged, .seconds(90))
      expectNoDifference(PlayerEvent.seekableChanged(true).seekableChanged, true)
      expectNoDifference(PlayerEvent.pausableChanged(false).pausableChanged, false)
      expectNoDifference(PlayerEvent.volumeChanged(0.75).volumeChanged, 0.75)
      expectNoDifference(PlayerEvent.voutChanged(2).voutChanged, 2)
      expectNoDifference(PlayerEvent.bufferingProgress(0.5).bufferingProgress, 0.5)
      expectNoDifference(PlayerEvent.chapterChanged(4).chapterChanged, 4)
      expectNoDifference(PlayerEvent.titleSelectionChanged(3).titleSelectionChanged, 3)
      expectNoDifference(PlayerEvent.snapshotTaken("/tmp/snapshot.png").snapshotTaken, "/tmp/snapshot.png")
      expectNoDifference(PlayerEvent.programAdded(7).programAdded, 7)
      expectNoDifference(PlayerEvent.programDeleted(8).programDeleted, 8)
      expectNoDifference(PlayerEvent.programUpdated(9).programUpdated, 9)

      #expect(PlayerEvent.tracksChanged.tracksChanged != nil)
      #expect(PlayerEvent.mediaChanged.mediaChanged != nil)
      #expect(PlayerEvent.encounteredError.encounteredError != nil)
      #expect(PlayerEvent.muted.muted != nil)
      #expect(PlayerEvent.unmuted.unmuted != nil)
      #expect(PlayerEvent.corked.corked != nil)
      #expect(PlayerEvent.uncorked.uncorked != nil)
      #expect(PlayerEvent.mediaStopping.mediaStopping != nil)
      #expect(PlayerEvent.titleListChanged.titleListChanged != nil)

      if case .some(.some(let device)) = PlayerEvent.audioDeviceChanged("built-in").audioDeviceChanged {
        expectNoDifference(device, "built-in")
      } else {
        Issue.record("Expected a wrapped non-nil audio device id")
      }

      if case .some(.none) = PlayerEvent.audioDeviceChanged(nil).audioDeviceChanged {
      } else {
        Issue.record("Expected a wrapped nil audio device id")
      }

      let recording = try #require(
        PlayerEvent.recordingChanged(isRecording: true, filePath: "/tmp/out.ts").recordingChanged
      )
      #expect(recording.isRecording)
      expectNoDifference(recording.filePath, "/tmp/out.ts")

      let stoppedRecording = try #require(
        PlayerEvent.recordingChanged(isRecording: false, filePath: nil).recordingChanged
      )
      #expect(!stoppedRecording.isRecording)
      expectNoDifference(stoppedRecording.filePath, nil)

      let selection = try #require(
        PlayerEvent.programSelected(unselectedId: 11, selectedId: 12).programSelected
      )
      expectNoDifference(selection.unselectedId, 11)
      expectNoDifference(selection.selectedId, 12)
    }

    @Test
    func `Per-case accessors return nil for non-matching events`() {
      let nilResults = [
        PlayerEvent.muted.stateChanged == nil,
        PlayerEvent.muted.timeChanged == nil,
        PlayerEvent.muted.positionChanged == nil,
        PlayerEvent.muted.lengthChanged == nil,
        PlayerEvent.muted.seekableChanged == nil,
        PlayerEvent.muted.pausableChanged == nil,
        PlayerEvent.muted.tracksChanged == nil,
        PlayerEvent.muted.mediaChanged == nil,
        PlayerEvent.muted.encounteredError == nil,
        PlayerEvent.muted.volumeChanged == nil,
        PlayerEvent.unmuted.muted == nil,
        PlayerEvent.muted.unmuted == nil,
        PlayerEvent.muted.corked == nil,
        PlayerEvent.muted.uncorked == nil,
        PlayerEvent.muted.audioDeviceChanged == nil,
        PlayerEvent.muted.mediaStopping == nil,
        PlayerEvent.muted.voutChanged == nil,
        PlayerEvent.muted.bufferingProgress == nil,
        PlayerEvent.muted.chapterChanged == nil,
        PlayerEvent.muted.recordingChanged == nil,
        PlayerEvent.muted.titleListChanged == nil,
        PlayerEvent.muted.titleSelectionChanged == nil,
        PlayerEvent.muted.snapshotTaken == nil,
        PlayerEvent.muted.programAdded == nil,
        PlayerEvent.muted.programDeleted == nil,
        PlayerEvent.muted.programSelected == nil,
        PlayerEvent.muted.programUpdated == nil
      ]

      expectNoDifference(nilResults, Array(repeating: true, count: nilResults.count))
    }
  }
}
