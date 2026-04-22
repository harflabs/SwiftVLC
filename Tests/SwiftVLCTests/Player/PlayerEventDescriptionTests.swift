@testable import SwiftVLC
import Testing

/// Covers `PlayerEvent.description` — the `CustomStringConvertible`
/// conformance used by logging and debugging output. Every case is
/// exercised with its own assertion so a typo in any one case
/// produces a named failure rather than a generic "didn't match".
@Suite(.tags(.logic))
struct PlayerEventDescriptionTests {
  @Test
  func `stateChanged embeds the state description`() {
    #expect(PlayerEvent.stateChanged(.playing).description == "stateChanged(playing)")
    #expect(PlayerEvent.stateChanged(.idle).description == "stateChanged(idle)")
    #expect(PlayerEvent.stateChanged(.error).description == "stateChanged(error)")
  }

  @Test
  func `timeChanged uses Duration formatted`() {
    #expect(PlayerEvent.timeChanged(.seconds(65)).description == "timeChanged(1:05)")
    #expect(PlayerEvent.timeChanged(.seconds(3665)).description == "timeChanged(1:01:05)")
  }

  @Test
  func `positionChanged shows the raw fractional value`() {
    #expect(PlayerEvent.positionChanged(0.5).description == "positionChanged(0.5)")
  }

  @Test
  func `lengthChanged uses Duration formatted`() {
    #expect(PlayerEvent.lengthChanged(.seconds(90)).description == "lengthChanged(1:30)")
  }

  @Test
  func `seekable and pausable render as Bool`() {
    #expect(PlayerEvent.seekableChanged(true).description == "seekableChanged(true)")
    #expect(PlayerEvent.pausableChanged(false).description == "pausableChanged(false)")
  }

  @Test
  func `Payload-free cases render their name`() {
    #expect(PlayerEvent.tracksChanged.description == "tracksChanged")
    #expect(PlayerEvent.mediaChanged.description == "mediaChanged")
    #expect(PlayerEvent.encounteredError.description == "encounteredError")
    #expect(PlayerEvent.muted.description == "muted")
    #expect(PlayerEvent.unmuted.description == "unmuted")
    #expect(PlayerEvent.corked.description == "corked")
    #expect(PlayerEvent.uncorked.description == "uncorked")
    #expect(PlayerEvent.mediaStopping.description == "mediaStopping")
    #expect(PlayerEvent.titleListChanged.description == "titleListChanged")
  }

  @Test
  func `volumeChanged embeds the Float value`() {
    #expect(PlayerEvent.volumeChanged(0.75).description == "volumeChanged(0.75)")
  }

  @Test
  func `audioDeviceChanged handles both String and nil`() {
    #expect(PlayerEvent.audioDeviceChanged("coreaudio").description == "audioDeviceChanged(coreaudio)")
    #expect(PlayerEvent.audioDeviceChanged(nil).description == "audioDeviceChanged(nil)")
  }

  @Test
  func `voutChanged renders the active output count`() {
    #expect(PlayerEvent.voutChanged(2).description == "voutChanged(2)")
  }

  @Test
  func `bufferingProgress embeds the Float value`() {
    #expect(PlayerEvent.bufferingProgress(0.42).description == "bufferingProgress(0.42)")
  }

  @Test
  func `chapterChanged renders the chapter index`() {
    #expect(PlayerEvent.chapterChanged(3).description == "chapterChanged(3)")
  }

  @Test
  func `recordingChanged handles both filePath and nil`() {
    #expect(
      PlayerEvent.recordingChanged(isRecording: true, filePath: "/tmp/a.ts").description
        == "recordingChanged(isRecording: true, filePath: /tmp/a.ts)"
    )
    #expect(
      PlayerEvent.recordingChanged(isRecording: false, filePath: nil).description
        == "recordingChanged(isRecording: false, filePath: nil)"
    )
  }

  @Test
  func `titleSelectionChanged renders the index`() {
    #expect(PlayerEvent.titleSelectionChanged(1).description == "titleSelectionChanged(1)")
  }

  @Test
  func `snapshotTaken renders the file path`() {
    #expect(PlayerEvent.snapshotTaken("/tmp/s.png").description == "snapshotTaken(/tmp/s.png)")
  }

  @Test
  func `Program events render the int id`() {
    #expect(PlayerEvent.programAdded(7).description == "programAdded(7)")
    #expect(PlayerEvent.programDeleted(8).description == "programDeleted(8)")
    #expect(PlayerEvent.programUpdated(9).description == "programUpdated(9)")
  }

  @Test
  func `programSelected renders both the unselected and selected ids`() {
    #expect(
      PlayerEvent.programSelected(unselectedId: 1, selectedId: 2).description
        == "programSelected(unselectedId: 1, selectedId: 2)"
    )
  }
}
