import CLibVLC
import Foundation

/// Generates thumbnails from media asynchronously.
///
/// ```swift
/// let data = try await media.thumbnail(at: .seconds(10), width: 320, height: 0)
/// ```
extension Media {
  /// Generates a thumbnail at the specified time.
  ///
  /// Supports cooperative cancellation — cancelling the parent `Task` will
  /// abort the thumbnail request.
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

    // Convert pointers to Int for Sendable compliance in onCancel closure.
    let mediaBits = Int(bitPattern: media)
    let instanceBits = Int(bitPattern: instancePtr)

    let result: Result<Data, VLCError> = await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        let box = Unmanaged.passRetained(
          ThumbnailContinuation(continuation: cont)
        ).toOpaque()

        libvlc_event_attach(
          em,
          Int32(libvlc_MediaThumbnailGenerated.rawValue),
          thumbnailCallback,
          box
        )

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
        )

        if request == nil {
          libvlc_event_detach(
            em,
            Int32(libvlc_MediaThumbnailGenerated.rawValue),
            thumbnailCallback,
            box
          )
          Unmanaged<ThumbnailContinuation>.fromOpaque(box).release()
          cont.resume(returning: .failure(.operationFailed("Generate thumbnail")))
        }
      }
    } onCancel: {
      // Best-effort cancellation: VLC doesn't expose a thumbnail cancel API,
      // but parsing stop will abort related work. The callback will still fire.
      let m = OpaquePointer(bitPattern: mediaBits)!
      let inst = OpaquePointer(bitPattern: instanceBits)!
      libvlc_media_parse_stop(inst, m)
    }
    return try result.get()
  }
}

// MARK: - Internals

private final class ThumbnailContinuation: @unchecked Sendable {
  let continuation: CheckedContinuation<Result<Data, VLCError>, Never>

  init(continuation: CheckedContinuation<Result<Data, VLCError>, Never>) {
    self.continuation = continuation
  }
}

private func thumbnailCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let box = Unmanaged<ThumbnailContinuation>.fromOpaque(opaque)
  let ctx = box.takeUnretainedValue()

  // Detach — one shot
  let p_obj = event.pointee.p_obj
  if let mediaPtr = p_obj {
    let em = libvlc_media_event_manager(OpaquePointer(mediaPtr))!
    libvlc_event_detach(
      em,
      Int32(libvlc_MediaThumbnailGenerated.rawValue),
      thumbnailCallback,
      opaque
    )
  }
  box.release()

  guard let picture = event.pointee.u.media_thumbnail_generated.p_thumbnail else {
    ctx.continuation.resume(returning: .failure(.operationFailed("Generate thumbnail: no image produced")))
    return
  }

  var size = 0
  guard let buffer = libvlc_picture_get_buffer(picture, &size), size > 0 else {
    ctx.continuation.resume(returning: .failure(.operationFailed("Generate thumbnail: empty buffer")))
    return
  }

  let data = Data(bytes: buffer, count: size)
  ctx.continuation.resume(returning: .success(data))
}
