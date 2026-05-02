import CLibVLC
import Foundation
import Synchronization

/// The type of a media source as reported by libVLC.
public enum MediaType: Sendable, Hashable, CustomStringConvertible {
  /// Media type could not be determined yet.
  case unknown
  /// A regular file on disk.
  case file
  /// A directory (used for folder-as-playlist behavior).
  case directory
  /// An optical disc (DVD, Blu-ray, Audio CD).
  case disc
  /// A network stream (HTTP, RTSP, etc.).
  case stream
  /// A playlist (M3U, PLS, XSPF, etc.).
  case playlist

  public var description: String {
    switch self {
    case .unknown: "unknown"
    case .file: "file"
    case .directory: "directory"
    case .disc: "disc"
    case .stream: "stream"
    case .playlist: "playlist"
    }
  }

  init(from cValue: libvlc_media_type_t) {
    switch cValue {
    case libvlc_media_type_file: self = .file
    case libvlc_media_type_directory: self = .directory
    case libvlc_media_type_disc: self = .disc
    case libvlc_media_type_stream: self = .stream
    case libvlc_media_type_playlist: self = .playlist
    default: self = .unknown
    }
  }
}

/// A slave track (subtitle or audio) attached to a ``Media``.
public struct MediaSlave: Sendable, Hashable {
  /// Resource URI of the slave file.
  public let uri: String
  /// Whether this slave is a subtitle or audio track.
  public let type: MediaSlaveType
  /// Priority. Higher values win when the same type appears multiple times.
  public let priority: Int
}

/// A media source that can be played by a ``Player``.
///
/// Create from a URL or file path, optionally parse for metadata:
/// ```swift
/// let media = try Media(url: streamURL)
/// let metadata = try await media.parse()
/// print(metadata.title ?? "Unknown")
/// ```
///
/// `Media` is `Sendable`. Create it on any actor, then hand it to a
/// `@MainActor` ``Player`` via `player.load(media)`.
public final class Media: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_t*
  let thumbnailCoordinator = ThumbnailCoordinator()

  /// Creates media from a URL.
  ///
  /// Works for both local `file://` URLs and remote `http://`/`rtsp://` streams.
  /// - Parameter url: The media source URL.
  /// - Throws: `VLCError.mediaCreationFailed` if the URL is invalid.
  public init(url: URL) throws(VLCError) {
    let mrl = url.isFileURL ? url.path : url.absoluteString
    guard
      let media = url.isFileURL
      ? libvlc_media_new_path(mrl)
      : libvlc_media_new_location(mrl)
    else {
      throw .mediaCreationFailed(source: url.absoluteString)
    }
    pointer = media
  }

  /// Creates media from a file path.
  /// - Parameter path: Absolute file path to the media file.
  /// - Throws: `VLCError.mediaCreationFailed` if the path is invalid.
  public init(path: String) throws(VLCError) {
    guard let media = libvlc_media_new_path(path) else {
      throw .mediaCreationFailed(source: path)
    }
    pointer = media
  }

  /// Parses the media's metadata and track list, awaiting the result.
  ///
  /// Reads both local and network sources. Cancelling the enclosing
  /// `Task` aborts the parse promptly, leaving the media untouched.
  ///
  /// - Parameters:
  ///   - timeout: Maximum time to wait before giving up.
  ///   - instance: The libVLC instance that performs the parse.
  /// - Returns: The parsed ``Metadata``. Call ``tracks()`` afterwards
  ///   to obtain the discovered tracks.
  /// - Throws: ``VLCError/parseTimeout`` if `timeout` expires, or
  ///   ``VLCError/parseFailed(reason:)`` for any other failure.
  public func parse(
    timeout: Duration = .seconds(10),
    instance: VLCInstance = .shared
  )
    async throws(VLCError) -> Metadata {
    let media = pointer
    let em = libvlc_media_event_manager(media)!
    let instancePtr = instance.pointer
    let operationRef = ParseOperationRef()

    // `onCancel` is a `@Sendable` closure and `OpaquePointer` isn't
    // Sendable, so bind the pointers to `nonisolated(unsafe)` locals —
    // the same pattern used elsewhere for libVLC pointer captures
    // (Player.deinit, PixelBufferRenderer). The pointers stay valid for
    // the duration of this call because `self` (Media) and `instance`
    // (VLCInstance) are retained by the surrounding `async` frame.
    nonisolated(unsafe) let cancelMedia = media
    nonisolated(unsafe) let cancelInstance = instancePtr

    let result: Result<Metadata, VLCError> = await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        let operation = ParseOperation(
          continuation: cont,
          media: media,
          eventManager: em,
          instance: instancePtr
        )
        operationRef.store(operation)

        if Task.isCancelled {
          operation.cancel()
          return
        }

        let box = Unmanaged.passRetained(operation).toOpaque()

        guard libvlc_event_attach(em, Int32(libvlc_MediaParsedChanged.rawValue), parseCallback, box) == 0 else {
          Unmanaged<ParseOperation>.fromOpaque(box).release()
          operation.finishWithoutRequest(
            with: .failure(.parseFailed(reason: "attach parsed callback"))
          )
          return
        }

        guard operation.installCallbackBox(box) else {
          libvlc_event_detach(em, Int32(libvlc_MediaParsedChanged.rawValue), parseCallback, box)
          Unmanaged<ParseOperation>.fromOpaque(box).release()
          return
        }

        if Task.isCancelled {
          operation.cancel()
          return
        }

        guard operation.beginRequest() else {
          return
        }

        let timeoutMs = Int32(timeout.milliseconds)
        let flags = libvlc_media_parse_flag_t(
          rawValue: libvlc_media_parse_local.rawValue | libvlc_media_parse_network.rawValue
        )
        let rc = libvlc_media_parse_request(instancePtr, media, flags, timeoutMs)
        if rc != 0 {
          operation.finishWithoutRequest(
            with: .failure(.parseFailed(reason: "parse request rejected"))
          )
          return
        }

        if Task.isCancelled {
          operation.cancel()
        }
      }
    } onCancel: {
      // Stop the in-progress parse. VLC will fire MediaParsedChanged
      // with a failed status, which resumes the continuation.
      if let operation = operationRef.value() {
        operation.cancel()
      } else {
        libvlc_media_parse_stop(cancelInstance, cancelMedia)
      }
    }
    operationRef.value()?.cleanupAfterCompletion()
    return try result.get()
  }

  /// Returns tracks discovered after parsing.
  ///
  /// Call ``parse(timeout:instance:)`` first, or tracks may be empty.
  public func tracks() -> [Track] {
    [libvlc_track_audio, libvlc_track_video, libvlc_track_text].flatMap { type -> [Track] in
      guard let tracklist = libvlc_media_get_tracklist(pointer, type) else { return [] }
      defer { libvlc_media_tracklist_delete(tracklist) }

      let count = libvlc_media_tracklist_count(tracklist)
      return (0..<count).compactMap { i in
        libvlc_media_tracklist_at(tracklist, i).map { Track(from: $0) }
      }
    }
  }

  /// The media resource locator (URL or file path used to create this media).
  public var mrl: String? {
    guard let cstr = libvlc_media_get_mrl(pointer) else { return nil }
    defer { libvlc_free(cstr) }
    return String(cString: cstr)
  }

  /// Duration of the media (available after parsing).
  public var duration: Duration? {
    let ms = libvlc_media_get_duration(pointer)
    guard ms >= 0 else { return nil }
    return .milliseconds(ms)
  }

  /// The category of this media source (file, stream, disc, etc.).
  ///
  /// Useful for tailoring UI: show a network indicator for `.stream`,
  /// a disc icon for `.disc`, and so on. Reports `.unknown` until
  /// libVLC has enough context to determine the type — immediately
  /// after creation for local paths, after parse for network URLs.
  public var mediaType: MediaType {
    MediaType(from: libvlc_media_get_type(pointer))
  }

  // MARK: - Slaves (external audio / subtitles)

  /// Attaches an external slave track (subtitles or audio) to this media.
  ///
  /// Slaves added here take effect when the media is played. For runtime
  /// additions during playback, use ``Player/addExternalTrack(from:type:select:)``.
  ///
  /// - Parameters:
  ///   - url: URL of the slave file (must be a valid URI, e.g. `file://`).
  ///   - type: Subtitle or audio.
  ///   - priority: Higher priorities are preferred when multiple slaves of
  ///     the same type are present. Must be non-negative and fit in a
  ///     `UInt32`. libVLC clamps the value to its user-slave ceiling
  ///     internally, so values above ~4 are normalized. Defaults to `4`
  ///     which matches libVLC's priority for user-added files.
  /// - Precondition: `priority` is in `0...UInt32.max`.
  /// - Throws: `VLCError.operationFailed` if the slave cannot be attached.
  public func addSlave(
    from url: URL,
    type: MediaSlaveType,
    priority: Int = 4
  )
    throws(VLCError) {
    precondition(
      priority >= 0 && priority <= Int(UInt32.max),
      "Slave priority \(priority) is out of range (0 ... \(UInt32.max))"
    )
    let uri = url.absoluteString
    guard libvlc_media_slaves_add(pointer, type.cValue, UInt32(priority), uri) == 0 else {
      throw .operationFailed("Add slave \(type) from \(uri)")
    }
  }

  /// Removes all slaves previously attached to this media.
  public func clearSlaves() {
    libvlc_media_slaves_clear(pointer)
  }

  /// Returns the current list of slaves attached to this media.
  public var slaves: [MediaSlave] {
    var slavesPtr: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_slave_t>?>?
    let count = libvlc_media_slaves_get(pointer, &slavesPtr)
    guard count > 0, let slavesPtr else { return [] }
    defer { libvlc_media_slaves_release(slavesPtr, count) }

    return (0..<Int(count)).compactMap { i -> MediaSlave? in
      guard let slave = slavesPtr[i]?.pointee else { return nil }
      return MediaSlave(
        uri: String(cString: slave.psz_uri),
        type: MediaSlaveType(from: slave.i_type),
        priority: Int(slave.i_priority)
      )
    }
  }

  /// Wraps an already-retained `libvlc_media_t` pointer.
  ///
  /// The caller must have already called `libvlc_media_retain` or obtained
  /// the pointer from an API that returns a retained reference.
  /// `Media` will call `libvlc_media_release` on deinit.
  init(retaining ptr: OpaquePointer) {
    pointer = ptr
  }

  /// Creates media from an open file descriptor.
  ///
  /// The file descriptor must be open for reading. libVLC will **not** close it.
  /// - Parameter fd: An open file descriptor.
  /// - Throws: `VLCError.mediaCreationFailed` if creation fails.
  public init(fileDescriptor fd: Int) throws(VLCError) {
    guard let media = libvlc_media_new_fd(Int32(fd)) else {
      throw .mediaCreationFailed(source: "fd:\(fd)")
    }
    pointer = media
  }

  /// Applies a libVLC option to this media before playback starts.
  ///
  /// Options use libVLC's command-line syntax, with a leading `:` for
  /// input options. For example, `:network-caching=1000` sets a
  /// one-second network buffer; `:start-time=30` skips the first 30
  /// seconds. Call this repeatedly to add multiple options. Options
  /// have no effect once the media has begun playing.
  public func addOption(_ option: String) {
    libvlc_media_add_option(pointer, option)
  }

  // MARK: - Metadata Editing

  /// Sets a metadata value on this media.
  ///
  /// Call ``saveMetadata(instance:)`` to persist changes.
  public func setMetadata(_ key: MetadataKey, value: String) {
    libvlc_media_set_meta(pointer, key.cValue, value)
  }

  /// Persists metadata changes to the media file.
  /// - Throws: `VLCError.operationFailed` if the metadata cannot be saved.
  public func saveMetadata(instance: VLCInstance = .shared) throws(VLCError) {
    guard libvlc_media_save_meta(instance.pointer, pointer) != 0 else {
      throw .operationFailed("Save metadata")
    }
  }

  deinit {
    libvlc_media_release(pointer)
  }
}

// MARK: - Parse Internals

private final class ParseOperationRef: Sendable {
  private let storage = Mutex<ParseOperation?>(nil)

  func store(_ operation: ParseOperation) {
    storage.withLock { $0 = operation }
  }

  func value() -> ParseOperation? {
    storage.withLock { $0 }
  }
}

private final class ParseOperation: Sendable {
  private struct State: @unchecked Sendable {
    var continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>?
    var callbackBox: UnsafeMutableRawPointer?
    var eventAttached = false
    var requestStarted = false
    var isCancellationRequested = false
    var isUserFinished = false
    var isCleanedUp = false
  }

  private struct Cleanup: @unchecked Sendable {
    let callbackBox: UnsafeMutableRawPointer?
    let shouldDetachEvent: Bool
  }

  private struct Resume: @unchecked Sendable {
    let continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>
    let result: Result<Metadata, VLCError>
  }

  nonisolated(unsafe) let media: OpaquePointer
  private nonisolated(unsafe) let eventManager: OpaquePointer
  private nonisolated(unsafe) let instance: OpaquePointer
  private let state: Mutex<State>

  init(
    continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>,
    media: OpaquePointer,
    eventManager: OpaquePointer,
    instance: OpaquePointer
  ) {
    self.media = media
    self.eventManager = eventManager
    self.instance = instance
    libvlc_media_retain(media)
    state = Mutex(State(continuation: continuation))
  }

  deinit {
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

  func beginRequest() -> Bool {
    state.withLock { state -> Bool in
      guard !state.isCleanedUp, !state.isUserFinished else { return false }
      state.requestStarted = true
      return true
    }
  }

  func cancel() {
    let resumeOrStop = state.withLock { state -> (Resume?, Bool) in
      guard !state.isUserFinished else { return (nil, false) }
      state.isCancellationRequested = true
      guard state.requestStarted else {
        return (
          finishUserLocked(
            &state,
            with: .failure(.parseFailed(reason: "cancelled"))
          ),
          false
        )
      }
      return (nil, true)
    }

    if resumeOrStop.1 {
      libvlc_media_parse_stop(instance, media)
    }
    if let resume = resumeOrStop.0 {
      resume.continuation.resume(returning: resume.result)
    }
  }

  func finishWithoutRequest(with result: Result<Metadata, VLCError>) {
    let resume = state.withLock { state -> Resume? in
      finishUserLocked(&state, with: result)
    }
    if let resume {
      resume.continuation.resume(returning: resume.result)
    }
  }

  func finishFromLibVLC(with result: Result<Metadata, VLCError>) {
    let resume = state.withLock { state -> Resume? in
      guard !state.isCleanedUp else { return nil }
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
    with result: Result<Metadata, VLCError>
  ) -> Resume? {
    guard !state.isUserFinished, let continuation = state.continuation else {
      return nil
    }
    state.isUserFinished = true
    state.continuation = nil
    let finalResult: Result<Metadata, VLCError> = state.isCancellationRequested
      ? .failure(.parseFailed(reason: "cancelled"))
      : result
    return Resume(continuation: continuation, result: finalResult)
  }

  private func makeCleanupLocked(_ state: inout State) -> Cleanup? {
    guard !state.isCleanedUp else { return nil }
    state.isCleanedUp = true

    let cleanup = Cleanup(
      callbackBox: state.callbackBox,
      shouldDetachEvent: state.eventAttached
    )

    state.callbackBox = nil
    state.eventAttached = false
    state.requestStarted = false
    return cleanup
  }

  private func performCleanup(_ cleanup: Cleanup?) {
    guard let cleanup else { return }
    if cleanup.shouldDetachEvent, let box = cleanup.callbackBox {
      libvlc_event_detach(
        eventManager,
        Int32(libvlc_MediaParsedChanged.rawValue),
        parseCallback,
        box
      )
    }

    if let box = cleanup.callbackBox {
      Unmanaged<ParseOperation>.fromOpaque(box).release()
    }
  }
}

private func parseCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let operation = Unmanaged<ParseOperation>.fromOpaque(opaque).takeUnretainedValue()
  let status = libvlc_media_parsed_status_t(
    rawValue: UInt32(event.pointee.u.media_parsed_changed.new_status)
  )

  let result: Result<Metadata, VLCError> = switch status {
  case libvlc_media_parsed_status_done:
    .success(Metadata(from: operation.media))
  case libvlc_media_parsed_status_timeout:
    .failure(.parseTimeout)
  default:
    .failure(.parseFailed(reason: "status: \(status.rawValue)"))
  }

  operation.finishFromLibVLC(with: result)
}
