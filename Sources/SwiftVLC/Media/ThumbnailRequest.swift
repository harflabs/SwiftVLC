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

    // `requestBox` stores only the libVLC request pointer and exposes an
    // idempotent destroy. It has no lifecycle dependency on the
    // ThumbnailContinuation box: both the callback and onCancel can call
    // `requestBox.destroy()` safely without risking a use-after-free, no
    // matter which one races first.
    let requestBox = RequestBox()

    let result: Result<Data, VLCError> = await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        let ctx = ThumbnailContinuation(
          continuation: cont,
          eventManager: em,
          requestBox: requestBox
        )
        let box = Unmanaged.passRetained(ctx).toOpaque()

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
          Unmanaged<ThumbnailContinuation>.fromOpaque(box).release()
          cont.resume(returning: .failure(.operationFailed("Generate thumbnail")))
          return
        }

        requestBox.store(request)
      }
    } onCancel: {
      // Destroy the in-flight request via the standalone request box. The
      // callback will still fire (with p_thumbnail == nil) and handle its
      // own cleanup / continuation resume. We never touch the Unmanaged
      // ThumbnailContinuation here, so the callback's box.release() and
      // onCancel can never race.
      requestBox.destroy()
    }
    return try result.get()
  }
}

// MARK: - Internals

/// Holds the libVLC `libvlc_media_thumbnail_request_t*` pointer. Its
/// `destroy()` is idempotent and atomic so the callback and the cancel
/// handler can both call it without stepping on each other.
private final class RequestBox: Sendable {
  private let bits = Mutex<Int>(0)

  func store(_ request: OpaquePointer) {
    bits.withLock { $0 = Int(bitPattern: UnsafeRawPointer(request)) }
  }

  /// Atomically clears the stored pointer and destroys it if present.
  /// Subsequent calls are no-ops.
  func destroy() {
    let captured = bits.withLock { value -> Int in
      let c = value
      value = 0
      return c
    }
    guard captured != 0, let ptr = OpaquePointer(bitPattern: captured) else { return }
    libvlc_media_thumbnail_request_destroy(ptr)
  }
}

private final class ThumbnailContinuation: Sendable {
  let continuation: CheckedContinuation<Result<Data, VLCError>, Never>
  nonisolated(unsafe) let eventManager: OpaquePointer
  let requestBox: RequestBox

  init(
    continuation: CheckedContinuation<Result<Data, VLCError>, Never>,
    eventManager: OpaquePointer,
    requestBox: RequestBox
  ) {
    self.continuation = continuation
    self.eventManager = eventManager
    self.requestBox = requestBox
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
  ctx.requestBox.destroy()

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
