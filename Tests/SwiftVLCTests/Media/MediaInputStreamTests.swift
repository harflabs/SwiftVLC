import Foundation
import Synchronization
import Testing

@testable import SwiftVLC

private final class InputProbe: Sendable {
  struct Counts {
    var opened = 0
    var closed = 0
    var reads = 0
    var seeks = 0
  }
  let counts = Mutex(Counts())
}

private struct BytesFactory: MediaInputFactory {
  let data: Data
  let probe: InputProbe
  func open() throws -> any MediaInputStream { ByteInput(data, probe: probe) }
}

private final class ByteInput: MediaInputStream, Sendable {
  struct State {
    var offset = 0
    var closed = false
  }
  let data: Data
  let probe: InputProbe
  let state = Mutex(State())
  var length: UInt64? { UInt64(data.count) }
  init(_ data: Data, probe: InputProbe) {
    self.data = data
    self.probe = probe
    probe.counts.withLock { $0.opened += 1 }
  }
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    state.withLock { state in
      guard !state.closed else { return 0 }
      let count = min(buffer.count, data.count - state.offset)
      if count > 0 {
        data.withUnsafeBytes {
          buffer.baseAddress!.copyMemory(
            from: $0.baseAddress!.advanced(by: state.offset), byteCount: count)
        }
      }
      state.offset += count
      probe.counts.withLock { $0.reads += 1 }
      return count
    }
  }
  func seek(to offset: UInt64) throws {
    guard offset <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    state.withLock { $0.offset = Int(offset) }
    probe.counts.withLock { $0.seeks += 1 }
  }
  func close() {
    state.withLock { state in
      guard !state.closed else { return }
      state.closed = true
      probe.counts.withLock { $0.closed += 1 }
    }
  }
  deinit { close() }
}

extension Integration {
  @Suite(.tags(.async), .timeLimit(.minutes(2)), .serialized)
  struct MediaInputStreamTests {
    @Test func parsesWithoutPlaintextURLAndReopensIndependentCursors() async throws {
      let probe = InputProbe()
      let media = try Media(
        input: BytesFactory(data: Data(contentsOf: TestMedia.silenceURL), probe: probe))
      _ = try await media.parse(instance: TestInstance.makeAudioOnly())
      let second = try Media(
        input: BytesFactory(data: Data(contentsOf: TestMedia.silenceURL), probe: probe))
      _ = try await second.parse(instance: TestInstance.makeAudioOnly())
      #expect(probe.counts.withLock { $0.opened } >= 2)
      #expect(probe.counts.withLock { $0.reads } > 0)
      #expect(media.duration != nil)
    }

    @Test @MainActor func playbackRetainsCallbacksThroughShutdownAfterWrapperReplacement()
      async throws
    {
      let probe = InputProbe()
      let player = Player(instance: TestInstance.makeAudioOnly())
      do {
        let media = try Media(
          input: BytesFactory(data: Data(contentsOf: TestMedia.twosecURL), probe: probe))
        try player.play(media)
      }
      try await Task.sleep(for: .milliseconds(250))
      #expect(probe.counts.withLock { $0.opened } > 0)
      player.load(try Media(url: TestMedia.silenceURL))
      await player.shutdown()
      #expect(probe.counts.withLock { $0.opened == $0.closed })
    }

    @Test func generatesThumbnailUsingCallbackInput() async throws {
      let probe = InputProbe()
      let media = try Media(
        input: BytesFactory(data: Data(contentsOf: TestMedia.testMP4URL), probe: probe))
      let image = try await media.thumbnail(at: .zero, width: 64, timeout: .seconds(15))
      #expect(!image.isEmpty)
      #expect(probe.counts.withLock { $0.opened } > 0)
    }

    @Test func factoryFailurePropagatesAsParseFailure() async throws {
      struct FailedFactory: MediaInputFactory {
        func open() throws -> any MediaInputStream { throw CocoaError(.fileReadCorruptFile) }
      }
      let media = try Media(input: FailedFactory())
      await #expect(throws: VLCError.self) {
        try await media.parse(timeout: .seconds(2), instance: TestInstance.makeAudioOnly())
      }
    }
  }
}
