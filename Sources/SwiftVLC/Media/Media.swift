import CLibVLC
import Foundation

/// A media source that can be played by a ``Player``.
///
/// Create from a URL or file path, optionally parse for metadata:
/// ```swift
/// let media = try Media(url: streamURL)
/// let metadata = try await media.parse()
/// print(metadata.title ?? "Unknown")
/// ```
///
/// `Media` is `Sendable` — create it anywhere, then pass to a `@MainActor` Player
/// via `player.load(media)`.
public final class Media: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_t*

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

  /// Parses media metadata asynchronously.
  ///
  /// Supports cooperative cancellation — cancelling the parent `Task` aborts the parse.
  /// - Parameters:
  ///   - timeout: Maximum time to wait for parsing.
  ///   - instance: VLC instance (needed for parse API in VLC 4.0).
  /// - Returns: Parsed ``Metadata``.
  /// - Throws: `VLCError.parseFailed` or `VLCError.parseTimeout`.
  public func parse(
    timeout: Duration = .seconds(10),
    instance: VLCInstance = .shared
  )
    async throws(VLCError) -> Metadata {
    let media = pointer
    let em = libvlc_media_event_manager(media)!
    let instancePtr = instance.pointer

    // Convert pointers to Int for Sendable compliance in onCancel closure.
    let mediaBits = Int(bitPattern: media)
    let instanceBits = Int(bitPattern: instancePtr)

    let result: Result<Metadata, VLCError> = await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        let box = Unmanaged.passRetained(ParseContinuation(continuation: cont, media: media)).toOpaque()

        libvlc_event_attach(em, Int32(libvlc_MediaParsedChanged.rawValue), parseCallback, box)

        let timeoutMs = Int32(timeout.milliseconds)
        let flags = libvlc_media_parse_flag_t(
          rawValue: libvlc_media_parse_local.rawValue | libvlc_media_parse_network.rawValue
        )
        let rc = libvlc_media_parse_request(instancePtr, media, flags, timeoutMs)
        if rc != 0 {
          libvlc_event_detach(em, Int32(libvlc_MediaParsedChanged.rawValue), parseCallback, box)
          Unmanaged<ParseContinuation>.fromOpaque(box).release()
          cont.resume(returning: .failure(.parseFailed(reason: "parse request rejected")))
        }
      }
    } onCancel: {
      // Stop the in-progress parse. VLC will fire MediaParsedChanged
      // with a failed status, which resumes the continuation.
      let m = OpaquePointer(bitPattern: mediaBits)!
      let inst = OpaquePointer(bitPattern: instanceBits)!
      libvlc_media_parse_stop(inst, m)
    }
    return try result.get()
  }

  /// Returns tracks discovered after parsing.
  ///
  /// Call ``parse(timeout:instance:)`` first, or tracks may be empty.
  public func tracks() -> [Track] {
    var result: [Track] = []
    for type in [libvlc_track_audio, libvlc_track_video, libvlc_track_text] {
      guard let tracklist = libvlc_media_get_tracklist(pointer, type) else { continue }
      defer { libvlc_media_tracklist_delete(tracklist) }

      let count = libvlc_media_tracklist_count(tracklist)
      for i in 0..<count {
        guard let track = libvlc_media_tracklist_at(tracklist, i) else { continue }
        result.append(Track(from: track))
      }
    }
    return result
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

  /// Creates media from an open file descriptor.
  ///
  /// The file descriptor must be open for reading. libVLC will **not** close it.
  /// - Parameter fileDescriptor: An open file descriptor.
  /// - Throws: `VLCError.mediaCreationFailed` if creation fails.
  public init(fileDescriptor fd: Int) throws(VLCError) {
    guard let media = libvlc_media_new_fd(Int32(fd)) else {
      throw .mediaCreationFailed(source: "fd:\(fd)")
    }
    pointer = media
  }

  /// Adds a VLC option string to this media (e.g. ":network-caching=1000").
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

private final class ParseContinuation: @unchecked Sendable {
  let continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>
  let media: OpaquePointer

  init(continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>, media: OpaquePointer) {
    self.continuation = continuation
    self.media = media
  }
}

private func parseCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let _ = event, let opaque else { return }

  let box = Unmanaged<ParseContinuation>.fromOpaque(opaque)
  let ctx = box.takeUnretainedValue()
  let em = libvlc_media_event_manager(ctx.media)!

  // Detach immediately — one-shot
  libvlc_event_detach(em, Int32(libvlc_MediaParsedChanged.rawValue), parseCallback, opaque)
  box.release()

  let status = libvlc_media_get_parsed_status(ctx.media)

  switch status {
  case libvlc_media_parsed_status_done:
    let metadata = Metadata(from: ctx.media)
    ctx.continuation.resume(returning: .success(metadata))
  case libvlc_media_parsed_status_timeout:
    ctx.continuation.resume(returning: .failure(.parseTimeout))
  default:
    ctx.continuation.resume(returning: .failure(.parseFailed(reason: "status: \(status.rawValue)")))
  }
}
