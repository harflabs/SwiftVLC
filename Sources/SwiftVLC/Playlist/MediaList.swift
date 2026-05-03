import CLibVLC

/// A thread-safe playlist of media items.
///
/// Mutating operations acquire the underlying libVLC lock automatically.
/// For batch reads that should see a consistent snapshot, use
/// ``withLocked(_:)`` to hold the lock across multiple calls.
///
/// ```swift
/// let list = MediaList()
/// let media = try Media(url: videoURL)
/// try list.append(media)
/// ```
///
/// Pair with a ``MediaListPlayer`` to play the items in sequence.
public final class MediaList: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_list_t*

  /// Creates an empty media list.
  public init() {
    guard let p = libvlc_media_list_new() else {
      preconditionFailure("Failed to allocate libvlc media list. Out of memory?")
    }
    pointer = p
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
  /// - Throws: `VLCError.operationFailed` if the list is read-only or the operation fails.
  public func append(_ media: borrowing Media) throws(VLCError) {
    libvlc_media_list_lock(pointer)
    defer { libvlc_media_list_unlock(pointer) }
    guard libvlc_media_list_add_media(pointer, media.pointer) == 0 else {
      throw .operationFailed("Append media to list")
    }
  }

  /// Inserts a media item at the specified index.
  /// - Throws: `VLCError.operationFailed` if the index is out of range or the list is read-only.
  public func insert(_ media: borrowing Media, at index: Int) throws(VLCError) {
    libvlc_media_list_lock(pointer)
    defer { libvlc_media_list_unlock(pointer) }
    guard libvlc_media_list_insert_media(pointer, media.pointer, Int32(index)) == 0 else {
      throw .operationFailed("Insert media at index \(index)")
    }
  }

  /// Removes the media item at the specified index.
  /// - Throws: `VLCError.operationFailed` if the index is out of range or the list is read-only.
  public func remove(at index: Int) throws(VLCError) {
    libvlc_media_list_lock(pointer)
    defer { libvlc_media_list_unlock(pointer) }
    guard libvlc_media_list_remove_index(pointer, Int32(index)) == 0 else {
      throw .operationFailed("Remove media at index \(index)")
    }
  }

  /// Whether the list is empty.
  public var isEmpty: Bool {
    count == 0
  }

  /// Accesses a media item by index (locks/unlocks for each access).
  ///
  /// For batch access, prefer ``withLocked(_:)`` to avoid repeated locking.
  public subscript(index: Int) -> Media? {
    media(at: index)
  }

  /// Accesses a media item at the given index within a locked scope.
  ///
  /// The returned `Media` is retained, and is safe to use after this
  /// call returns.
  /// - Parameter index: Zero-based index.
  /// - Returns: The media at that index, or `nil` if out of bounds.
  public func media(at index: Int) -> Media? {
    libvlc_media_list_lock(pointer)
    defer { libvlc_media_list_unlock(pointer) }
    guard let mediaPtr = libvlc_media_list_item_at_index(pointer, Int32(index)) else {
      return nil
    }
    return Media(retaining: mediaPtr)
  }

  // MARK: - Scoped Access (~Copyable, ~Escapable)

  /// Provides safe, scoped access to the media list while holding its lock.
  ///
  /// The `LockedView` is `~Copyable` and `~Escapable`. It cannot be
  /// stored, duplicated, returned, or escaped to a `Task`. The compiler
  /// enforces this at build time, so the lock is held for exactly the
  /// duration of `body` and no longer.
  ///
  /// ```swift
  /// let total = list.withLocked { view in
  ///     (0..<view.count).compactMap { view.media(at: $0)?.mrl }
  /// }
  /// ```
  ///
  /// - Parameter body: A closure that receives a locked, non-copyable view.
  /// - Returns: The value returned by `body`.
  public func withLocked<R>(_ body: (borrowing LockedView) throws -> R) rethrows -> R {
    libvlc_media_list_lock(pointer)
    defer { libvlc_media_list_unlock(pointer) }
    let view = LockedView(list: self)
    return try body(view)
  }

  /// A non-copyable, non-escapable scoped view into a locked ``MediaList``.
  ///
  /// Cannot be stored in a property, returned from a function,
  /// or escaped to a `Task`. The compiler enforces this at build time
  /// via `~Copyable` and `~Escapable`.
  public struct LockedView: ~Copyable, ~Escapable {
    private let pointer: OpaquePointer

    @_lifetime(borrow list)
    init(list: borrowing MediaList) {
      pointer = list.pointer
    }

    /// Number of items in the list (no additional lock needed).
    public var count: Int {
      Int(libvlc_media_list_count(pointer))
    }

    /// Whether the list is empty.
    public var isEmpty: Bool {
      count == 0
    }

    /// Returns the media at the given index, or `nil` if out of bounds.
    ///
    /// The returned `Media` is retained and safe to use after the
    /// locked scope ends.
    public func media(at index: Int) -> Media? {
      guard let ptr = libvlc_media_list_item_at_index(pointer, Int32(index)) else {
        return nil
      }
      return Media(retaining: ptr)
    }

    /// Subscript access to media at the given index.
    public subscript(index: Int) -> Media? {
      media(at: index)
    }
  }
}
