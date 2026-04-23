import CLibVLC

/// Image overlay (logo) controls.
///
/// `~Copyable` and `~Escapable`. Must be used inline; cannot be stored
/// in properties or captured in closures. The compiler-enforced scope
/// rules out a dangling pointer if the player is deallocated.
///
/// ```swift
/// player.logo.isEnabled = true
/// player.logo.setFile("/path/to/logo.png")
/// player.logo.opacity = 200
/// ```
@MainActor
public struct Logo: ~Copyable, ~Escapable {
  private let pointer: OpaquePointer

  @_lifetime(borrow player)
  init(player: borrowing Player) {
    pointer = player.pointer
  }

  /// Whether the logo overlay is enabled.
  public var isEnabled: Bool {
    get { libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_enable.rawValue)) != 0 }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_enable.rawValue), newValue ? 1 : 0) }
  }

  /// Sets the logo image file path(s).
  ///
  /// libVLC does not expose a getter for the current logo file, so this
  /// is a write-only operation.
  ///
  /// Format: `"file"` for a single image or
  /// `"file,delay,transparency;file,delay,transparency;..."` for an
  /// animated sequence.
  public func setFile(_ file: String) {
    libvlc_video_set_logo_string(pointer, UInt32(libvlc_logo_file.rawValue), file)
  }

  /// Horizontal pixel offset from the ``position`` anchor (positive = rightward).
  public var x: Int {
    get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_x.rawValue))) }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_x.rawValue), Int32(newValue)) }
  }

  /// Vertical pixel offset from the ``position`` anchor (positive = downward).
  public var y: Int {
    get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_y.rawValue))) }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_y.rawValue), Int32(newValue)) }
  }

  /// Logo opacity (0-255).
  public var opacity: Int {
    get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_opacity.rawValue))) }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_opacity.rawValue), Int32(newValue)) }
  }

  /// Delay between images in milliseconds.
  public var delay: Int {
    get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_delay.rawValue))) }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_delay.rawValue), Int32(newValue)) }
  }

  /// Number of loops (-1 for infinite).
  public var repeatCount: Int {
    get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_repeat.rawValue))) }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_repeat.rawValue), Int32(newValue)) }
  }

  /// Screen position as a bitmask: `0` = center, `1` = left, `2` = right,
  /// `4` = top, `8` = bottom. Combine horizontal and vertical flags with
  /// bitwise OR (e.g. `4 | 1` for top-left).
  public var position: Int {
    get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_position.rawValue))) }
    nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_position.rawValue), Int32(newValue)) }
  }

  /// Shows a logo overlay with the given file, in one call.
  ///
  /// Flipping `Enable` before the `File` property is set activates the
  /// filter with no image to draw; this method sets the file and any
  /// visual attributes first, then enables.
  ///
  /// ```swift
  /// player.logo.show(file: logoPath, opacity: 200, position: 4 | 2)
  /// ```
  ///
  /// - Parameters:
  ///   - file: Path to the logo image, or a
  ///     `"path,delay,transparency;path,delay,transparency;..."` sequence.
  ///   - opacity: `0-255`. Defaults to fully opaque.
  ///   - position: Position bitmask. Defaults to `0` (center).
  public func show(
    file: String,
    opacity: Int = 255,
    position: Int = 0
  ) {
    setFile(file)
    self.opacity = opacity
    self.position = position
    isEnabled = true
  }

  /// Hides the logo overlay (equivalent to `isEnabled = false`).
  public func hide() {
    isEnabled = false
  }
}
