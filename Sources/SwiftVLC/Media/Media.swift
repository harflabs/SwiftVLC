import CLibVLC
import Foundation

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
  /// Priority — higher values are preferred when the same type appears
  /// multiple times.
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
  /// Useful for tailoring UI — e.g. show a network indicator for `.stream`,
  /// or a disc icon for `.disc`. Reported as `.unknown` until libVLC has
  /// enough context to determine the type (usually immediately after
  /// creation for local paths, after parse for network URLs).
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

private final class ParseContinuation: Sendable {
  let continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>
  nonisolated(unsafe) let media: OpaquePointer

  init(continuation: CheckedContinuation<Result<Metadata, VLCError>, Never>, media: OpaquePointer) {
    self.continuation = continuation
    self.media = media
  }
}

private func parseCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard event != nil, let opaque else { return }

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
