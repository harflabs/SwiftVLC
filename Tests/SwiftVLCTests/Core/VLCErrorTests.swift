@testable import SwiftVLC
import Foundation
import Testing

@Suite("VLCError", .tags(.logic))
struct VLCErrorTests {
  @Test(
    "Description for all cases",
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
  func descriptionForAllCases(error: VLCError, expected: String) {
    #expect(error.description == expected)
  }

  @Test(
    "errorDescription matches description",
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
  func errorDescriptionMatchesDescription(error: VLCError) {
    #expect(error.errorDescription == error.description)
  }

  @Test("Conforms to LocalizedError")
  func conformsToLocalizedError() {
    let error: any Error = VLCError.parseTimeout
    #expect(error is any LocalizedError)
  }

  @Test("Conforms to CustomStringConvertible")
  func conformsToCustomStringConvertible() {
    let error: VLCError = .parseTimeout
    let str = String(describing: error)
    #expect(str.contains("parsing timed out"))
  }

  @Test("Associated values appear in description")
  func associatedValuesAppearInDescription() {
    let error = VLCError.mediaCreationFailed(source: "test.mp4")
    #expect(error.description.contains("test.mp4"))
  }

  @Test("Is Sendable")
  func isSendable() {
    let error: VLCError = .parseTimeout
    let sendable: any Sendable = error
    _ = sendable
  }
}
