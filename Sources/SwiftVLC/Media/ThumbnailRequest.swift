import CLibVLC
import Foundation
import Synchronization

/// Generates thumbnails from media asynchronously.
///
/// ```swift
/// let data = try await media.thumbnail(at: .seconds(10), width: 320, height: 0)
/// ```
extension Media {
  /// Generates a thumbnail at the specified time.
  ///
  /// Supports cooperative cancellation — cancelling the parent `Task` aborts
  /// the in-flight thumbnail request via `libvlc_media_thumbnail_request_destroy`.
  ///
  /// - Parameters:
  ///   - time: Time position to capture the thumbnail.
  ///   - width: Desired width (0 to derive from aspect ratio).
  ///   - height: Desired height (0 to derive from aspect ratio).
  ///   - crop: Whether to crop to match exact dimensions.
  ///   - timeout: Maximum time to wait.
  ///   - instance: VLC instance.
  /// - Returns: The raw image data (PNG format).
  /// - Throws: `VLCError.operationFailed` if thumbnail generation fails.
  public func thumbnail(
    at time: Duration,
    width: Int = 320,
    height: Int = 0,
    crop: Bool = false,
    timeout: Duration = .seconds(10),
    instance: VLCInstance = .shared
  )
    async throws(VLCError) -> Data {
    let media = pointer
    let em = libvlc_media_event_manager(media)!
    let instancePtr = instance.pointer

    // Shared holder for the ThumbnailContinuation box pointer. The inner
    // continuation closure stores it after attaching the event; the outer
    // onCancel closure reads it to destroy the in-flight request.
    let boxHolder = PointerBox()

    let result: Result<Data, VLCError> = await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        let ctx = ThumbnailContinuation(
          continuation: cont,
          eventManager: em
        )
        let box = Unmanaged.passRetained(ctx).toOpaque()
        boxHolder.store(box)

        libvlc_event_attach(
          em,
          Int32(libvlc_MediaThumbnailGenerated.rawValue),
          thumbnailCallback,
          box
        )

        guard
          let request = libvlc_media_thumbnail_request_by_time(
            instancePtr,
            media,
            time.milliseconds,
            libvlc_media_thumbnail_seek_fast,
            UInt32(width),
            UInt32(height),
            crop,
            libvlc_picture_Png,
            timeout.milliseconds
          ) else {
          libvlc_event_detach(
            em,
            Int32(libvlc_MediaThumbnailGenerated.rawValue),
            thumbnailCallback,
            box
          )
          boxHolder.clear()
          Unmanaged<ThumbnailContinuation>.fromOpaque(box).release()
          cont.resume(returning: .failure(.operationFailed("Generate thumbnail")))
          return
        }

        ctx.setRequest(request)
      }
    } onCancel: {
      // Destroy the in-flight request. libVLC will then fire
      // MediaThumbnailGenerated with p_thumbnail == nil, which the callback
      // resumes as a failure — we never resume the continuation here.
      guard let box = boxHolder.load() else { return }
      let ctx = Unmanaged<ThumbnailContinuation>.fromOpaque(box).takeUnretainedValue()
      ctx.destroyRequest()
    }
    return try result.get()
  }
}

// MARK: - Internals

/// Thread-safe holder for a single raw pointer, shared between the
/// continuation closure and the onCancel closure.
private final class PointerBox: Sendable {
  private let bits = Mutex<Int>(0)

  func store(_ pointer: UnsafeMutableRawPointer) {
    bits.withLock { $0 = Int(bitPattern: pointer) }
  }

  func clear() {
    bits.withLock { $0 = 0 }
  }

  func load() -> UnsafeMutableRawPointer? {
    let value = bits.withLock { $0 }
    return UnsafeMutableRawPointer(bitPattern: value)
  }
}

private final class ThumbnailContinuation: Sendable {
  let continuation: CheckedContinuation<Result<Data, VLCError>, Never>
  nonisolated(unsafe) let eventManager: OpaquePointer
  private let requestBits = Mutex<Int>(0)

  init(
    continuation: CheckedContinuation<Result<Data, VLCError>, Never>,
    eventManager: OpaquePointer
  ) {
    self.continuation = continuation
    self.eventManager = eventManager
  }

  func setRequest(_ request: OpaquePointer) {
    requestBits.withLock { $0 = Int(bitPattern: UnsafeRawPointer(request)) }
  }

  /// Destroys the stored thumbnail request pointer. Idempotent — safe to call
  /// from both the callback (cleanup) and the cancellation handler.
  func destroyRequest() {
    let bits = requestBits.withLock { value -> Int in
      let captured = value
      value = 0
      return captured
    }
    guard bits != 0, let ptr = OpaquePointer(bitPattern: bits) else { return }
    libvlc_media_thumbnail_request_destroy(ptr)
  }
}

private func thumbnailCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let box = Unmanaged<ThumbnailContinuation>.fromOpaque(opaque)
  let ctx = box.takeUnretainedValue()

  // Always detach and free the request before resuming.
  libvlc_event_detach(
    ctx.eventManager,
    Int32(libvlc_MediaThumbnailGenerated.rawValue),
    thumbnailCallback,
    opaque
  )
  ctx.destroyRequest()

  let resumeValue: Result<Data, VLCError>
  if let picture = event.pointee.u.media_thumbnail_generated.p_thumbnail {
    var size = 0
    if let buffer = libvlc_picture_get_buffer(picture, &size), size > 0 {
      resumeValue = .success(Data(bytes: buffer, count: size))
    } else {
      resumeValue = .failure(.operationFailed("Generate thumbnail: empty buffer"))
    }
  } else {
    resumeValue = .failure(.operationFailed("Generate thumbnail: no image produced"))
  }

  ctx.continuation.resume(returning: resumeValue)
  box.release()
}
