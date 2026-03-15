@testable import SwiftVLC
import Foundation
import Testing

@Suite(.tags(.logic))
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
}
