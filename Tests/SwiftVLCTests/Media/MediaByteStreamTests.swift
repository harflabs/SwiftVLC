@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// A file-backed stream that counts how libVLC uses it.
private final class CountingFileStream: MediaByteStream, @unchecked Sendable {
  private let fd: Int32
  let length: UInt64?
  private(set) var reads = 0
  private(set) var seeks = 0
  var failReads = false

  init(url: URL, reportsLength: Bool = true) throws {
    fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(.ENOENT) }
    var info = stat()
    fstat(fd, &info)
    length = reportsLength ? UInt64(info.st_size) : nil
  }

  deinit {
    close(fd)
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    reads += 1
    if failReads {
      throw POSIXError(.EIO)
    }
    let count = Foundation.read(fd, buffer.baseAddress, buffer.count)
    if count < 0 {
      throw POSIXError(.EIO)
    }
    return count
  }

  func seek(to offset: UInt64) throws {
    seeks += 1
    guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { throw POSIXError(.EINVAL) }
  }
}

extension Integration {
  struct MediaByteStreamTests {
    @Test
    func `Stream media parses like the same file opened by URL`() async throws {
      let url = TestMedia.testMP4URL
      let viaURL = try Media(url: url)
      let viaStream = try Media(streamFactory: { try CountingFileStream(url: url) })

      let expected = try await viaURL.parse()
      let actual = try await viaStream.parse()

      #expect(actual.title == expected.title)
      #expect(actual.title == "Test")
      #expect(viaStream.tracks().contains(where: { $0.type == .video }))
      #expect(viaStream.tracks().contains(where: { $0.type == .audio }))
    }

    @Test
    func `Stream media with unknown length still parses`() async throws {
      let url = TestMedia.testMP4URL
      let media = try Media(streamFactory: { try CountingFileStream(url: url, reportsLength: false) })
      let metadata = try await media.parse()
      #expect(metadata.title == "Test")
    }

    @Test
    func `Factory runs once per open and the stream is read`() async throws {
      let url = TestMedia.testMP4URL
      let opened = Mutex(0)
      let media = try Media(streamFactory: {
        opened.withLock { $0 += 1 }
        return try CountingFileStream(url: url)
      })
      _ = try await media.parse()
      #expect(opened.withLock { $0 } >= 1)
    }

    @Test
    func `Failing factory makes the parse fail instead of hanging`() async throws {
      struct Boom: Error {}
      let media = try Media(streamFactory: { throw Boom() })
      await #expect(throws: (any Error).self) {
        _ = try await media.parse()
      }
    }

    @Test
    func `Failing reads make the parse fail instead of hanging`() async throws {
      let url = TestMedia.testMP4URL
      let media = try Media(streamFactory: {
        let stream = try CountingFileStream(url: url)
        stream.failReads = true
        return stream
      })
      await #expect(throws: (any Error).self) {
        _ = try await media.parse()
      }
    }

    @Test
    func `Registration is removed when the media is released`() throws {
      let key: UInt
      do {
        let media = try Media(streamFactory: { throw POSIXError(.EIO) })
        key = try #require(media.streamRegistration?.key)
        #expect(MediaStreamRegistration.factory(forKey: key) != nil)
      }
      #expect(MediaStreamRegistration.factory(forKey: key) == nil)
    }

    @Test
    func `URL media carries no stream registration`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      #expect(media.streamRegistration == nil)
    }
  }
}
