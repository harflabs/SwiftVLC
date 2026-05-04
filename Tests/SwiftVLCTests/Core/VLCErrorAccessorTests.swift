@testable import SwiftVLC
import CustomDump
import Testing

extension Logic {
  struct VLCErrorAccessorTests {
    @Test
    func `Per-case accessors return associated payloads`() {
      #expect(VLCError.instanceCreationFailed.instanceCreationFailed != nil)
      expectNoDifference(VLCError.mediaCreationFailed(source: "file.mp4").mediaCreationFailed, "file.mp4")
      expectNoDifference(VLCError.playbackFailed(reason: "codec").playbackFailed, "codec")
      expectNoDifference(VLCError.parseFailed(reason: "bad input").parseFailed, "bad input")
      #expect(VLCError.parseTimeout.parseTimeout != nil)
      expectNoDifference(VLCError.trackNotFound(id: "audio-1").trackNotFound, "audio-1")
      expectNoDifference(VLCError.invalidState("not loaded").invalidState, "not loaded")
      expectNoDifference(VLCError.invalidInput("width").invalidInput, "width")
      expectNoDifference(VLCError.operationFailed("Snapshot").operationFailed, "Snapshot")
    }

    @Test
    func `Per-case accessors return nil for non-matching errors`() {
      let nilResults = [
        VLCError.parseTimeout.instanceCreationFailed == nil,
        VLCError.parseTimeout.mediaCreationFailed == nil,
        VLCError.parseTimeout.playbackFailed == nil,
        VLCError.parseTimeout.parseFailed == nil,
        VLCError.instanceCreationFailed.parseTimeout == nil,
        VLCError.parseTimeout.trackNotFound == nil,
        VLCError.parseTimeout.invalidState == nil,
        VLCError.parseTimeout.invalidInput == nil,
        VLCError.parseTimeout.operationFailed == nil
      ]

      expectNoDifference(nilResults, Array(repeating: true, count: nilResults.count))
    }
  }
}
