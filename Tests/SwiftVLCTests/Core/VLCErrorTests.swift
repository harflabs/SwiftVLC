@testable import SwiftVLC
import Foundation
import Testing

extension Logic {
  struct VLCErrorTests {
    @Test(
      arguments: [
        (VLCError.instanceCreationFailed, "Failed to create libVLC instance"),
        (.mediaCreationFailed(source: "test.mp4"), "Failed to create media from: test.mp4"),
        (.playbackFailed(reason: "codec error"), "Playback failed: codec error"),
        (.parseFailed(reason: "timeout"), "Media parsing failed: timeout"),
        (.parseTimeout, "Media parsing timed out"),
        (.trackNotFound(id: "audio-0"), "Track not found: audio-0"),
        (.invalidState("not playing"), "Invalid state: not playing"),
        (.operationFailed("Snapshot"), "Snapshot failed")
      ] as [(VLCError, String)]
    )
    func `Description for all cases`(error: VLCError, expected: String) {
      #expect(error.description == expected)
    }

    @Test(
      arguments: [
        VLCError.instanceCreationFailed,
        .mediaCreationFailed(source: "x"),
        .playbackFailed(reason: "y"),
        .parseFailed(reason: "z"),
        .parseTimeout,
        .trackNotFound(id: "t"),
        .invalidState("s"),
        .operationFailed("o"),
      ]
    )
    func `errorDescription matches description`(error: VLCError) {
      #expect(error.errorDescription == error.description)
    }

    @Test
    func `Conforms to LocalizedError`() {
      let error: any Error = VLCError.parseTimeout
      #expect(error is any LocalizedError)
    }

    @Test
    func `Conforms to CustomStringConvertible`() {
      let error: VLCError = .parseTimeout
      let str = String(describing: error)
      #expect(str.contains("parsing timed out"))
    }

    @Test
    func `Associated values appear in description`() {
      let error = VLCError.mediaCreationFailed(source: "test.mp4")
      #expect(error.description.contains("test.mp4"))
    }

    @Test
    func `Is Sendable`() {
      let error: VLCError = .parseTimeout
      let sendable: any Sendable = error
      _ = sendable
    }

    @Test
    func `Equatable matches like cases by associated value`() {
      #expect(VLCError.parseTimeout == .parseTimeout)
      #expect(VLCError.parseTimeout != .instanceCreationFailed)
      #expect(VLCError.mediaCreationFailed(source: "a.mp4") == .mediaCreationFailed(source: "a.mp4"))
      #expect(VLCError.mediaCreationFailed(source: "a.mp4") != .mediaCreationFailed(source: "b.mp4"))
      #expect(VLCError.trackNotFound(id: "0") != .invalidState("0"))
    }

    @Test
    func `Hashable lets errors be deduplicated in a Set`() {
      let errors: Set<VLCError> = [
        .parseTimeout,
        .parseTimeout,
        .mediaCreationFailed(source: "a"),
        .mediaCreationFailed(source: "a"),
        .mediaCreationFailed(source: "b")
      ]
      // .parseTimeout collapses to 1; mediaCreationFailed has 2 distinct sources.
      #expect(errors.count == 3)
    }
  }
}
