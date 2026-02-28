import CLibVLC
import Foundation

/// A thread-safe playlist of media items.
///
/// The underlying `libvlc_media_list_t` uses internal locking.
/// All mutating operations acquire/release the lock automatically.
///
/// ```swift
/// let list = MediaList()
/// let media = try Media(url: videoURL)
/// list.append(media)
/// ```
public final class MediaList: Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_list_t*

    /// Creates an empty media list.
    public init() {
        pointer = libvlc_media_list_new()!
    }

    /// Wraps an existing libvlc_media_list_t pointer (retains it).
    init(retaining ptr: OpaquePointer) {
        _ = libvlc_media_list_retain(ptr)
        pointer = ptr
    }

    deinit {
        libvlc_media_list_release(pointer)
    }

    /// Number of items in the list.
    public var count: Int {
        libvlc_media_list_lock(pointer)
        defer { libvlc_media_list_unlock(pointer) }
        return Int(libvlc_media_list_count(pointer))
    }

    /// Whether the list is read-only.
    public var isReadOnly: Bool {
        libvlc_media_list_is_readonly(pointer)
    }

    /// Appends a media item to the end of the list.
    public func append(_ media: Media) throws(VLCError) {
        libvlc_media_list_lock(pointer)
        defer { libvlc_media_list_unlock(pointer) }
        guard libvlc_media_list_add_media(pointer, media.pointer) == 0 else {
            throw .operationFailed
        }
    }

    /// Inserts a media item at the specified index.
    public func insert(_ media: Media, at index: Int) throws(VLCError) {
        libvlc_media_list_lock(pointer)
        defer { libvlc_media_list_unlock(pointer) }
        guard libvlc_media_list_insert_media(pointer, media.pointer, Int32(index)) == 0 else {
            throw .operationFailed
        }
    }

    /// Removes the media item at the specified index.
    public func remove(at index: Int) throws(VLCError) {
        libvlc_media_list_lock(pointer)
        defer { libvlc_media_list_unlock(pointer) }
        guard libvlc_media_list_remove_index(pointer, Int32(index)) == 0 else {
            throw .operationFailed
        }
    }
}
