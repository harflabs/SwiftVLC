import CLibVLC
import Foundation
import Synchronization

/// A byte source that libVLC reads media from instead of opening a URL itself.
///
/// Conform to this to feed libVLC from something it cannot open directly, or
/// from a source where *how* the bytes are read matters. A typical case is a
/// network file system that is mounted locally: libVLC's own `file` access
/// reads it in small blocks with the operating system's read-ahead turned
/// off, which is slow when every request costs a network round trip. A custom
/// stream can read large blocks and keep its own read-ahead.
///
/// libVLC calls a stream from one thread at a time and may move it between
/// threads, so a conforming type can keep unsynchronized mutable state if it
/// declares `@unchecked Sendable`. The stream is closed by releasing it:
/// release resources in `deinit`.
///
/// ```swift
/// final class FileStream: MediaByteStream, @unchecked Sendable {
///   private let handle: FileHandle
///   let length: UInt64?
///   init(url: URL) throws { /* open, measure */ }
///   func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { /* ... */ }
///   func seek(to offset: UInt64) throws { /* ... */ }
/// }
/// let media = try Media(streamFactory: { try FileStream(url: url) })
/// ```
public protocol MediaByteStream: AnyObject, Sendable {
  /// Total length in bytes, or `nil` if unknown.
  ///
  /// Demuxers use it to find data at the end of a file (an MP4 `moov` box,
  /// for example), so report it whenever it is known.
  var length: UInt64? { get }

  /// Reads up to `buffer.count` bytes into `buffer`.
  ///
  /// - Returns: The number of bytes read, which must be greater than zero
  ///   unless the end of the stream is reached, in which case `0`. Blocking
  ///   until data is available is allowed.
  /// - Throws: Any error. libVLC treats it as a non-recoverable read failure.
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

  /// Moves the read position to an absolute byte offset.
  /// - Throws: Any error. libVLC treats it as a failed seek.
  func seek(to offset: UInt64) throws
}

/// Keeps the stream factory of a ``Media`` reachable for libVLC's open
/// callback without handing libVLC a pointer whose lifetime it cannot see.
///
/// libVLC may call the open callback after the Swift ``Media`` wrapper is gone
/// (the player opens its input asynchronously), and offers no hook to free the
/// callback's opaque pointer. An integer key looked up in a table turns that
/// case into a clean "not found" instead of a dangling pointer.
final class MediaStreamRegistration: Sendable {
  typealias Factory = @Sendable () throws -> any MediaByteStream

  private struct Table {
    var nextKey: UInt = 1
    var factories: [UInt: Factory] = [:]
  }

  private static let table = Mutex(Table())

  let key: UInt

  init(factory: @escaping Factory) {
    key = Self.table.withLock { table in
      let key = table.nextKey
      table.nextKey += 1
      table.factories[key] = factory
      return key
    }
  }

  deinit {
    _ = Self.table.withLock { $0.factories.removeValue(forKey: key) }
  }

  static func factory(forKey key: UInt) -> Factory? {
    table.withLock { $0.factories[key] }
  }

  /// Weak index from a libvlc media to the registration it was created with.
  /// A wrapper made from a bare native pointer (the player's current media)
  /// finds the registration here, while the registration is still alive.
  /// Keyed by the native address, which is not `Sendable` as an `OpaquePointer`.
  private static let registeredMedia = Mutex<[UInt: WeakRegistration]>([:])

  /// Records that `media` was created with this registration.
  func attach(to media: OpaquePointer) {
    let address = UInt(bitPattern: media)
    Self.registeredMedia.withLock {
      $0 = $0.filter { $0.value.registration != nil }
      $0[address] = WeakRegistration(self)
    }
  }

  /// The registration of a stream-backed native media, if it is still alive.
  static func registration(forMedia media: OpaquePointer) -> MediaStreamRegistration? {
    let address = UInt(bitPattern: media)
    return registeredMedia.withLock { $0[address]?.registration }
  }
}

/// A weak reference, read and written only under the lock of `registeredMedia`.
private final class WeakRegistration: @unchecked Sendable {
  weak var registration: MediaStreamRegistration?

  init(_ registration: MediaStreamRegistration) {
    self.registration = registration
  }
}

/// The retained object behind the `void *` that libVLC hands to the read,
/// seek and close callbacks of one opened stream.
private final class OpenedStream {
  let stream: any MediaByteStream
  init(_ stream: any MediaByteStream) {
    self.stream = stream
  }
}

// MARK: - C callbacks

private func mediaStreamOpen(
  _ opaque: UnsafeMutableRawPointer?,
  _ datap: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  _ sizep: UnsafeMutablePointer<UInt64>?
) -> Int32 {
  guard
    let opaque,
    let datap,
    let sizep,
    let factory = MediaStreamRegistration.factory(forKey: UInt(bitPattern: opaque))
  else { return -1 }
  guard let stream = try? factory() else { return -1 }
  datap.pointee = Unmanaged.passRetained(OpenedStream(stream)).toOpaque()
  sizep.pointee = stream.length ?? UInt64.max
  return 0
}

private func mediaStreamRead(
  _ opaque: UnsafeMutableRawPointer?,
  _ buffer: UnsafeMutablePointer<UInt8>?,
  _ length: Int
) -> Int {
  guard let opaque, let buffer else { return -1 }
  guard length > 0 else { return 0 }
  let opened = Unmanaged<OpenedStream>.fromOpaque(opaque).takeUnretainedValue()
  do {
    return try opened.stream.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: length))
  } catch {
    return -1
  }
}

private func mediaStreamSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: UInt64) -> Int32 {
  guard let opaque else { return -1 }
  let opened = Unmanaged<OpenedStream>.fromOpaque(opaque).takeUnretainedValue()
  do {
    try opened.stream.seek(to: offset)
    return 0
  } catch {
    return -1
  }
}

private func mediaStreamClose(_ opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }
  Unmanaged<OpenedStream>.fromOpaque(opaque).release()
}

extension Media {
  /// Creates media that libVLC reads through a ``MediaByteStream``.
  ///
  /// `streamFactory` runs each time libVLC opens the media (for playback and
  /// again for any later replay), on a libVLC thread. Return a fresh stream
  /// positioned at offset zero, or throw to make the open fail.
  ///
  /// libVLC does not look for sidecar files (external subtitles) next to a
  /// media it cannot locate by path. Add them with the player's subtitle API.
  ///
  /// - Parameters:
  ///   - streamFactory: Opens the byte source.
  ///   - isSeekable: Pass `false` for a stream whose ``MediaByteStream/seek(to:)``
  ///     is unsupported, so libVLC does not try to use it.
  /// - Throws: ``VLCError/mediaCreationFailed(source:)`` if libVLC cannot
  ///   create the media.
  public convenience init(
    streamFactory: @escaping @Sendable () throws -> any MediaByteStream,
    isSeekable: Bool = true
  )
    throws(VLCError) {
    let registration = MediaStreamRegistration(factory: streamFactory)
    guard
      let media = libvlc_media_new_callbacks(
        mediaStreamOpen,
        mediaStreamRead,
        isSeekable ? mediaStreamSeek : nil,
        mediaStreamClose,
        UnsafeMutableRawPointer(bitPattern: registration.key)
      )
    else {
      throw .mediaCreationFailed(source: "stream")
    }
    registration.attach(to: media)
    self.init(retaining: media, streamRegistration: registration)
  }
}
