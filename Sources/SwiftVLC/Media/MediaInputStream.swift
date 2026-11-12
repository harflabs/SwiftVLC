import CLibVLC
import Foundation
import Synchronization

/// One independently seekable input. Callbacks run on libVLC worker threads.
/// Implementations must serialize their own state and make close idempotent.
public protocol MediaInputStream: AnyObject, Sendable {
  var length: UInt64? { get }
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
  func seek(to offset: UInt64) throws
  func close()
}

/// Creates a new cursor for every parse, thumbnail, or playback input.
public protocol MediaInputFactory: Sendable {
  func open() throws -> any MediaInputStream
}

final class MediaInputResource: Sendable {
  let factory: any MediaInputFactory
  init(_ factory: any MediaInputFactory) { self.factory = factory }
}

private final class WeakInputResource: @unchecked Sendable {
  weak var value: MediaInputResource?
  init(_ value: MediaInputResource) { self.value = value }
}

enum MediaInputResources {
  private static let resources = Mutex<[UInt: WeakInputResource]>([:])
  static func register(_ resource: MediaInputResource, for pointer: OpaquePointer) {
    resources.withLock { values in
      values = values.filter { $0.value.value != nil }
      values[UInt(bitPattern: pointer)] = WeakInputResource(resource)
    }
  }
  static func resource(for pointer: OpaquePointer) -> MediaInputResource? {
    resources.withLock { $0[UInt(bitPattern: pointer)]?.value }
  }
}

extension Media {
  /// Creates media without a plaintext URL or intermediate file.
  public convenience init(input: any MediaInputFactory) throws(VLCError) {
    let resource = MediaInputResource(input)
    let opaque = Unmanaged.passUnretained(resource).toOpaque()
    guard
      let pointer = libvlc_media_new_callbacks(
        inputOpen, inputRead, inputSeek, inputClose, opaque
      )
    else { throw .mediaCreationFailed(source: "custom-input") }
    self.init(retaining: pointer)
    inputResource.withLock { $0 = resource }
    MediaInputResources.register(resource, for: pointer)
  }
}

private func inputOpen(
  _ opaque: UnsafeMutableRawPointer?,
  _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  _ size: UnsafeMutablePointer<UInt64>?
) -> Int32 {
  guard let opaque, let data, let size else { return -1 }
  let resource = Unmanaged<MediaInputResource>.fromOpaque(opaque).takeUnretainedValue()
  do {
    let session = InputSession(stream: try resource.factory.open(), resource: resource)
    size.pointee = session.stream.length ?? UInt64.max
    data.pointee = Unmanaged.passRetained(session).toOpaque()
    return 0
  } catch { return -1 }
}

private final class InputSession: Sendable {
  let stream: any MediaInputStream
  let resource: MediaInputResource
  init(stream: any MediaInputStream, resource: MediaInputResource) {
    self.stream = stream
    self.resource = resource
  }
  deinit { stream.close() }
}

private func inputRead(
  _ opaque: UnsafeMutableRawPointer?, _ bytes: UnsafeMutablePointer<UInt8>?, _ count: Int
) -> Int {
  guard let opaque, count >= 0, count == 0 || bytes != nil else { return -1 }
  let session = Unmanaged<InputSession>.fromOpaque(opaque).takeUnretainedValue()
  do {
    let read = try session.stream.read(
      into: UnsafeMutableRawBufferPointer(start: bytes, count: count))
    return (0...count).contains(read) ? read : -1
  } catch { return -1 }
}

private func inputSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: UInt64) -> Int32 {
  guard let opaque else { return -1 }
  do {
    try Unmanaged<InputSession>.fromOpaque(opaque).takeUnretainedValue().stream.seek(to: offset)
    return 0
  } catch { return -1 }
}

private func inputClose(_ opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }
  Unmanaged<InputSession>.fromOpaque(opaque).release()
}
