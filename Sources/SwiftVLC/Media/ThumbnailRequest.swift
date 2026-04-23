import CLibVLC
import Foundation
import Synchronization

/// How libVLC should locate the source frame when generating a thumbnail.
public enum ThumbnailSeekMode: Sendable, Hashable {
  /// Snap to the nearest keyframe. Fast but imprecise — for videos with
  /// sparse keyframes (e.g. Big Buck Bunny), every thumbnail can land on
  /// the same frame regardless of the requested offset. Use for library
  /// cover art where the exact frame doesn't matter.
  case fast

  /// Decode intervening frames until the exact requested offset is
  /// reached. Slower but visually correct — required for scrubber
  /// previews or time-accurate thumbnails.
  case precise

  var cValue: libvlc_thumbnailer_seek_speed_t {
    switch self {
    case .fast: libvlc_media_thumbnail_seek_fast
    case .precise: libvlc_media_thumbnail_seek_precise
    }
  }
}

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
  ///   - seekMode: How libVLC locates the source frame. Defaults to
  ///     ``ThumbnailSeekMode/precise`` — scrubber previews and
  ///     time-accurate thumbnails need the exact frame. Use
  ///     ``ThumbnailSeekMode/fast`` if you're generating library
  ///     cover art and speed matters more than frame accuracy.
  ///   - timeout: Maximum time to wait.
  ///   - instance: VLC instance.
  /// - Returns: The raw image data (PNG format).
  /// - Throws: `VLCError.operationFailed` if thumbnail generation fails.
  public func thumbnail(
    at time: Duration,
    width: Int = 320,
    height: Int = 0,
    crop: Bool = false,
    seekMode: ThumbnailSeekMode = .precise,
    timeout: Duration = .seconds(10),
    instance: VLCInstance = .shared
  )
    async throws(VLCError) -> Data {
    try await thumbnailCoordinator.acquire()
    // Structured release: bind the coordinator into a local actor
    // reference so we can release synchronously at the end of this
    // function. The old `defer { Task { await release() } }` form
    // deferred the release into an unstructured task, which meant a
    // second thumbnail on the same Media could see the coordinator
    // still "busy" and block even though the first caller had
    // returned — a stall that looked like "thumbnails queue up."
    let coordinator = thumbnailCoordinator

    if Task.isCancelled {
      await coordinator.release()
      throw .operationFailed("Generate thumbnail: cancelled")
    }

    let media = pointer
    let em = libvlc_media_event_manager(media)!
    let instancePtr = instance.pointer
    let operationRef = ThumbnailOperationRef()

    let result: Result<Data, VLCError> = await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        let operation = ThumbnailOperation(
          continuation: cont,
          eventManager: em
        )
        operationRef.store(operation)
        let box = Unmanaged.passRetained(operation).toOpaque()

        guard
          libvlc_event_attach(
            em,
            Int32(libvlc_MediaThumbnailGenerated.rawValue),
            thumbnailCallback,
            box
          ) == 0 else {
          Unmanaged<ThumbnailOperation>.fromOpaque(box).release()
          operation.finish(with: .failure(.operationFailed("Generate thumbnail: attach callback")))
          return
        }

        guard operation.installCallbackBox(box) else {
          // The operation was already finished (typically by `onCancel`
          // racing between `passRetained` above and this check), so
          // `finish()` didn't see a `callbackBox` to release. We own
          // the retain here and must release it ourselves, or the
          // `ThumbnailOperation` (with its `CheckedContinuation` /
          // `Mutex` state) leaks.
          libvlc_event_detach(
            em,
            Int32(libvlc_MediaThumbnailGenerated.rawValue),
            thumbnailCallback,
            box
          )
          Unmanaged<ThumbnailOperation>.fromOpaque(box).release()
          return
        }

        if Task.isCancelled {
          operation.cancel()
          return
        }

        guard
          let request = libvlc_media_thumbnail_request_by_time(
            instancePtr,
            media,
            time.milliseconds,
            seekMode.cValue,
            UInt32(width),
            UInt32(height),
            crop,
            libvlc_picture_Png,
            timeout.milliseconds
          ) else {
          operation.finish(with: .failure(.operationFailed("Generate thumbnail")))
          return
        }

        guard operation.storeRequest(request) else {
          libvlc_media_thumbnail_request_destroy(request)
          return
        }

        if Task.isCancelled {
          operation.cancel()
        }
      }
    } onCancel: {
      operationRef.value()?.cancel()
    }
    await coordinator.release()
    return try result.get()
  }
}

// MARK: - Internals

actor ThumbnailCoordinator {
  private var isBusy = false
  private var waiters: [ThumbnailGate] = []

  func acquire() async throws(VLCError) {
    guard !Task.isCancelled else {
      throw .operationFailed("Generate thumbnail: cancelled")
    }

    guard isBusy else {
      isBusy = true
      return
    }

    let gate = ThumbnailGate()
    waiters.append(gate)
    guard await gate.wait() else {
      throw .operationFailed("Generate thumbnail: cancelled")
    }
  }

  func release() {
    while !waiters.isEmpty {
      let gate = waiters.removeFirst()
      if gate.open() {
        return
      }
    }

    isBusy = false
  }
}

/// Async gate used by `ThumbnailCoordinator` to serialize media-wide
/// thumbnail generation.
private final class ThumbnailGate: @unchecked Sendable {
  private enum Status: @unchecked Sendable {
    case waiting
    case open
    case cancelled
  }

  private struct Storage: @unchecked Sendable {
    var continuation: CheckedContinuation<Bool, Never>?
    var status: Status = .waiting
  }

  private let storage = Mutex(Storage())

  func wait() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediateResult = storage.withLock { storage -> Bool? in
          switch storage.status {
          case .open:
            return true
          case .cancelled:
            return false
          case .waiting:
            storage.continuation = continuation
            return nil
          }
        }

        if let immediateResult {
          continuation.resume(returning: immediateResult)
        }
      }
    } onCancel: {
      cancel()
    }
  }

  @discardableResult
  func open() -> Bool {
    let (opened, continuation) = storage.withLock { storage
      -> (Bool, CheckedContinuation<Bool, Never>?) in
      guard storage.status == .waiting else { return (false, nil) }
      storage.status = .open
      let continuation = storage.continuation
      storage.continuation = nil
      return (true, continuation)
    }
    continuation?.resume(returning: true)
    return opened
  }

  private func cancel() {
    let continuation = storage.withLock { storage -> CheckedContinuation<Bool, Never>? in
      guard storage.status == .waiting else { return nil }
      storage.status = .cancelled
      let continuation = storage.continuation
      storage.continuation = nil
      return continuation
    }
    continuation?.resume(returning: false)
  }
}

private final class ThumbnailOperationRef: Sendable {
  private let storage = Mutex<ThumbnailOperation?>(nil)

  func store(_ operation: ThumbnailOperation) {
    storage.withLock { $0 = operation }
  }

  func value() -> ThumbnailOperation? {
    storage.withLock { $0 }
  }
}

private final class ThumbnailOperation: Sendable {
  private struct State: @unchecked Sendable {
    var continuation: CheckedContinuation<Result<Data, VLCError>, Never>?
    var request: OpaquePointer?
    var callbackBox: UnsafeMutableRawPointer?
    var eventAttached = false
    var isFinished = false
  }

  private struct Cleanup {
    let continuation: CheckedContinuation<Result<Data, VLCError>, Never>?
    let request: OpaquePointer?
    let callbackBox: UnsafeMutableRawPointer?
    let shouldDetachEvent: Bool
  }

  nonisolated(unsafe) let eventManager: OpaquePointer
  private let state: Mutex<State>

  init(
    continuation: CheckedContinuation<Result<Data, VLCError>, Never>,
    eventManager: OpaquePointer
  ) {
    self.eventManager = eventManager
    state = Mutex(State(continuation: continuation))
  }

  func installCallbackBox(_ box: UnsafeMutableRawPointer) -> Bool {
    state.withLock { state -> Bool in
      guard !state.isFinished else { return false }
      state.callbackBox = box
      state.eventAttached = true
      return true
    }
  }

  func storeRequest(_ request: OpaquePointer) -> Bool {
    state.withLock { state -> Bool in
      guard !state.isFinished else { return false }
      state.request = request
      return true
    }
  }

  func cancel() {
    finish(with: .failure(.operationFailed("Generate thumbnail: cancelled")))
  }

  func finish(with result: Result<Data, VLCError>) {
    let cleanup = state.withLock { state -> Cleanup? in
      guard !state.isFinished else { return nil }
      state.isFinished = true

      let cleanup = Cleanup(
        continuation: state.continuation,
        request: state.request,
        callbackBox: state.callbackBox,
        shouldDetachEvent: state.eventAttached
      )

      state.continuation = nil
      state.request = nil
      state.callbackBox = nil
      state.eventAttached = false
      return cleanup
    }
    guard let cleanup else { return }

    if cleanup.shouldDetachEvent, let box = cleanup.callbackBox {
      libvlc_event_detach(
        eventManager,
        Int32(libvlc_MediaThumbnailGenerated.rawValue),
        thumbnailCallback,
        box
      )
    }

    if let request = cleanup.request {
      libvlc_media_thumbnail_request_destroy(request)
    }

    cleanup.continuation?.resume(returning: result)

    if let box = cleanup.callbackBox {
      Unmanaged<ThumbnailOperation>.fromOpaque(box).release()
    }
  }
}

private func thumbnailCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let operation = Unmanaged<ThumbnailOperation>.fromOpaque(opaque).takeUnretainedValue()

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

  operation.finish(with: resumeValue)
}
