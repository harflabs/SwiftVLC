import CLibVLC
import Foundation
import Synchronization

/// How libVLC should locate the source frame when generating a thumbnail.
public enum ThumbnailSeekMode: Sendable, Hashable {
  /// Snap to the nearest keyframe. Fast but imprecise: videos with
  /// sparse keyframes (Big Buck Bunny is one example) can return the
  /// same frame for every offset. Use for library cover art where the
  /// exact frame doesn't matter.
  case fast

  /// Decode intervening frames until the exact requested offset is
  /// reached. Slower but visually correct. Required for scrubber
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
  /// Supports cooperative cancellation. If libVLC has already accepted
  /// the request, SwiftVLC waits for its terminal thumbnail event before
  /// returning so callback and request teardown are complete.
  ///
  /// - Parameters:
  ///   - time: Time position to capture the thumbnail.
  ///   - width: Desired width (0 to derive from aspect ratio).
  ///   - height: Desired height (0 to derive from aspect ratio).
  ///   - crop: Whether to crop to match exact dimensions.
  ///   - seekMode: How libVLC locates the source frame. Defaults to
  ///     ``ThumbnailSeekMode/precise``; scrubber previews and
  ///     time-accurate thumbnails need the exact frame. Use
  ///     ``ThumbnailSeekMode/fast`` for library cover art where
  ///     speed matters more than frame accuracy.
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
    // deferred the release into an unstructured task; a second
    // thumbnail on the same Media could then see the coordinator still
    // "busy" and block even though the first caller had already
    // returned, which looked like "thumbnails queue up."
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
          media: media,
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
          operation.finishWithoutRequest(
            with: .failure(.operationFailed("Generate thumbnail: attach callback"))
          )
          return
        }

        guard operation.installCallbackBox(box) else {
          // The operation was already finished (typically by `onCancel`
          // racing between `passRetained` above and this check), so
          // `cancel()` didn't see a `callbackBox` to release. We own
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

        guard operation.beginRequestCreation() else {
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
          if Task.isCancelled {
            operation.cancel()
          }
          operation.finishRequestCreation(with: nil)
          return
        }

        if Task.isCancelled {
          operation.cancel()
        }
        operation.finishRequestCreation(with: request)

        if Task.isCancelled {
          operation.cancel()
        }
      }
    } onCancel: {
      operationRef.value()?.cancel()
    }
    operationRef.value()?.cleanupAfterCompletion()
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
    // Pointers live inside `State` so the Mutex's release-acquire
    // pairing establishes a happens-before relation between the init
    // (writer thread) and the libVLC event-thread callback (reader).
    // ThreadSanitizer cannot see libVLC's internal synchronization; the
    // explicit lock here makes the ordering visible without changing
    // observable behavior — these pointers are write-once at init.
    let media: OpaquePointer
    let eventManager: OpaquePointer
    var continuation: CheckedContinuation<Result<Data, VLCError>, Never>?
    var request: OpaquePointer?
    var callbackBox: UnsafeMutableRawPointer?
    var eventAttached = false
    var requestCreationInFlight = false
    var pendingLibVLCResult: Result<Data, VLCError>?
    var isCancellationRequested = false
    var isUserFinished = false
    var isCleanedUp = false
  }

  private struct Cleanup: @unchecked Sendable {
    let request: OpaquePointer?
    let callbackBox: UnsafeMutableRawPointer?
    let shouldDetachEvent: Bool
    let eventManager: OpaquePointer
  }

  private struct Resume: @unchecked Sendable {
    let continuation: CheckedContinuation<Result<Data, VLCError>, Never>
    let result: Result<Data, VLCError>
  }

  private let state: Mutex<State>

  /// The event manager this operation listens on. Read through the lock
  /// so callers (including the libVLC callback thread) get a TSan-visible
  /// happens-before from init.
  var eventManager: OpaquePointer {
    state.withLock { $0.eventManager }
  }

  init(
    continuation: CheckedContinuation<Result<Data, VLCError>, Never>,
    media: OpaquePointer,
    eventManager: OpaquePointer
  ) {
    libvlc_media_retain(media)
    state = Mutex(State(
      media: media,
      eventManager: eventManager,
      continuation: continuation
    ))
  }

  deinit {
    let media = state.withLock { $0.media }
    libvlc_media_release(media)
  }

  func installCallbackBox(_ box: UnsafeMutableRawPointer) -> Bool {
    state.withLock { state -> Bool in
      guard !state.isCleanedUp, !state.isUserFinished else { return false }
      state.callbackBox = box
      state.eventAttached = true
      return true
    }
  }

  func beginRequestCreation() -> Bool {
    state.withLock { state -> Bool in
      guard !state.isCleanedUp, !state.isUserFinished else { return false }
      state.requestCreationInFlight = true
      return true
    }
  }

  func finishRequestCreation(with request: OpaquePointer?) {
    let resume = state.withLock { state -> Resume? in
      state.requestCreationInFlight = false

      guard let request else {
        return finishUserLocked(
          &state,
          with: .failure(.operationFailed("Generate thumbnail"))
        )
      }

      state.request = request
      guard let pendingResult = state.pendingLibVLCResult else { return nil }
      state.pendingLibVLCResult = nil
      return finishUserLocked(&state, with: pendingResult)
    }
    if let resume {
      resume.continuation.resume(returning: resume.result)
    }
  }

  func finishWithoutRequest(with result: Result<Data, VLCError>) {
    let resume = state.withLock { state -> Resume? in
      finishUserLocked(&state, with: result)
    }
    if let resume {
      resume.continuation.resume(returning: resume.result)
    }
  }

  func cancel() {
    let resume = state.withLock { state -> Resume? in
      guard !state.isUserFinished else { return nil }
      state.isCancellationRequested = true
      if state.request != nil || state.requestCreationInFlight {
        return nil
      }
      return finishUserLocked(
        &state,
        with: .failure(.operationFailed("Generate thumbnail: cancelled"))
      )
    }
    if let resume {
      resume.continuation.resume(returning: resume.result)
    }
  }

  func finishFromLibVLC(with result: Result<Data, VLCError>) {
    let resume = state.withLock { state -> Resume? in
      guard !state.isCleanedUp else { return nil }
      if state.requestCreationInFlight, state.request == nil {
        state.pendingLibVLCResult = result
        return nil
      }
      return finishUserLocked(&state, with: result)
    }
    if let resume {
      resume.continuation.resume(returning: resume.result)
    }
  }

  func cleanupAfterCompletion() {
    let cleanup = state.withLock { state -> Cleanup? in
      makeCleanupLocked(&state)
    }
    performCleanup(cleanup)
  }

  private func finishUserLocked(
    _ state: inout State,
    with result: Result<Data, VLCError>
  ) -> Resume? {
    guard !state.isUserFinished, let continuation = state.continuation else {
      return nil
    }
    state.isUserFinished = true
    state.continuation = nil
    let finalResult: Result<Data, VLCError> = state.isCancellationRequested
      ? .failure(.operationFailed("Generate thumbnail: cancelled"))
      : result
    return Resume(continuation: continuation, result: finalResult)
  }

  private func makeCleanupLocked(_ state: inout State) -> Cleanup? {
    guard !state.isCleanedUp else { return nil }
    state.isCleanedUp = true

    let cleanup = Cleanup(
      request: state.request,
      callbackBox: state.callbackBox,
      shouldDetachEvent: state.eventAttached,
      eventManager: state.eventManager
    )

    state.request = nil
    state.callbackBox = nil
    state.eventAttached = false
    state.requestCreationInFlight = false
    return cleanup
  }

  private func performCleanup(_ cleanup: Cleanup?) {
    guard let cleanup else { return }
    if cleanup.shouldDetachEvent, let box = cleanup.callbackBox {
      libvlc_event_detach(
        cleanup.eventManager,
        Int32(libvlc_MediaThumbnailGenerated.rawValue),
        thumbnailCallback,
        box
      )
    }

    if let request = cleanup.request {
      libvlc_media_thumbnail_request_destroy(request)
    }

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

  operation.finishFromLibVLC(with: resumeValue)
}
