import CLibVLC

/// Text overlay (marquee) controls.
///
/// `~Copyable` and `~Escapable`. Must be used inline; cannot be stored
/// in properties or captured in closures. The compiler-enforced scope
/// rules out a dangling pointer if the player is deallocated.
///
/// ```swift
/// player.marquee.isEnabled = true
/// player.marquee.setText("Now Playing")
/// player.marquee.fontSize = 24
/// ```
@MainActor
public struct Marquee: ~Copyable, ~Escapable {
  private let player: Player

  @_lifetime(borrow player)
  init(player: borrowing Player) {
    self.player = copy player
  }

  private var pointer: OpaquePointer {
    player.pointer
  }

  /// Whether the marquee overlay is enabled.
  public var isEnabled: Bool {
    get { libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Enable.rawValue)) != 0 }
    nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Enable.rawValue), newValue ? 1 : 0) }
  }

  /// Sets the marquee text content.
  ///
  /// libVLC does not expose a getter for the current marquee text, so
  /// this is a write-only operation. Store your own copy in application
  /// state if you need to read it back.
  ///
  /// Supports strftime-style placeholders (e.g. `%H:%M:%S`) which are
  /// refreshed at the interval configured by ``refresh``.
  public func setText(_ text: String) {
    player._marqueeText = text
    libvlc_video_set_marquee_string(pointer, UInt32(libvlc_marquee_Text.rawValue), text)
  }

  /// Text color as an RGB integer (e.g. 0xFF0000 for red).
  public var color: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Color.rawValue))) }
    nonmutating set {
      writeInt(libvlc_marquee_Color, newValue)
      bustTextRenderCache()
    }
  }

  /// Text opacity (0-255).
  public var opacity: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Opacity.rawValue))) }
    nonmutating set {
      writeInt(libvlc_marquee_Opacity, newValue)
      bustTextRenderCache()
    }
  }

  /// Font size in pixels.
  public var fontSize: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Size.rawValue))) }
    nonmutating set {
      writeInt(libvlc_marquee_Size, newValue)
      bustTextRenderCache()
    }
  }

  /// Horizontal pixel offset from the ``position`` anchor (positive = rightward).
  public var x: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_X.rawValue))) }
    nonmutating set { writeInt(libvlc_marquee_X, newValue) }
  }

  /// Vertical pixel offset from the ``position`` anchor (positive = downward).
  public var y: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Y.rawValue))) }
    nonmutating set { writeInt(libvlc_marquee_Y, newValue) }
  }

  /// Timeout in milliseconds (0 for permanent).
  public var timeout: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Timeout.rawValue))) }
    nonmutating set { writeInt(libvlc_marquee_Timeout, newValue) }
  }

  /// Refresh interval in milliseconds for time-based format strings (e.g. `%H:%M:%S`).
  public var refresh: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Refresh.rawValue))) }
    nonmutating set { writeInt(libvlc_marquee_Refresh, newValue) }
  }

  /// Screen position as a bitmask: `0` = center, `1` = left, `2` = right,
  /// `4` = top, `8` = bottom. Combine horizontal and vertical flags with
  /// bitwise OR (e.g. `4 | 1` for top-left).
  public var position: Int {
    get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Position.rawValue))) }
    nonmutating set { writeInt(libvlc_marquee_Position, newValue) }
  }

  /// Shows a marquee overlay with the given text, in one call.
  ///
  /// libVLC requires the marquee to have text *and* visible visual
  /// attributes *before* the Enable flag is flipped. Otherwise the
  /// filter activates with `NULL` text or a zero-size font and draws
  /// nothing. This method sets every prerequisite, then enables, so
  /// callers don't have to remember the sequence.
  ///
  /// ```swift
  /// player.marquee.show(text: "LIVE", fontSize: 32, color: 0xFF0000)
  /// ```
  ///
  /// - Parameters:
  ///   - text: The text to display. `strftime`-style placeholders
  ///     (`%H:%M:%S`) refresh at the interval set by ``refresh``.
  ///   - fontSize: Point size in pixels. Defaults to `24`.
  ///   - color: RGB color as an integer (e.g. `0xFFFFFF` for white).
  ///     Defaults to white.
  ///   - opacity: Opacity, `0-255`. Defaults to fully opaque.
  ///   - position: Screen position bitmask. Defaults to `0` (center).
  ///   - timeout: Milliseconds before the overlay auto-hides, or `0`
  ///     for permanent. Defaults to permanent.
  public func show(
    text: String,
    fontSize: Int = 24,
    color: Int = 0xFFFFFF,
    opacity: Int = 255,
    position: Int = 0,
    timeout: Int = 0
  ) {
    // Stage raw values directly, skipping the style setters. Using
    // those setters here would schedule a cache-bust per write on a
    // filter that hasn't been instantiated yet.
    setText(text)
    writeInt(libvlc_marquee_Size, fontSize)
    writeInt(libvlc_marquee_Color, color)
    writeInt(libvlc_marquee_Opacity, opacity)
    writeInt(libvlc_marquee_Position, position)
    writeInt(libvlc_marquee_Timeout, timeout)
    // Off→on unconditionally: creates the filter if it wasn't running, and
    // recreates it fresh if it was (otherwise `Enable = 1` while already
    // enabled is a libVLC no-op, and the new vars wouldn't be picked up).
    writeInt(libvlc_marquee_Enable, 0)
    writeInt(libvlc_marquee_Enable, 1)
  }

  /// Hides the marquee overlay (equivalent to `isEnabled = false`).
  public func hide() {
    isEnabled = false
  }

  private func writeInt(_ option: libvlc_video_marquee_option_t, _ value: Int) {
    libvlc_video_set_marquee_int(pointer, UInt32(option.rawValue), Int32(value))
  }

  /// Forces libVLC's text renderer to re-rasterize the marquee glyphs with
  /// the current style.
  ///
  /// libVLC's `freetype` module caches rasterized text bitmaps keyed on the
  /// *text string*; a style-only write (color, opacity, or font size) updates
  /// the filter's internal state but still hits the cached bitmap, so the
  /// overlay keeps the old look until the text itself changes. We bust the
  /// cache by briefly writing a padded variant of the current text, then
  /// restoring the original on the next main-actor tick. The intermediate
  /// write produces a cache miss that re-renders with the new style, and
  /// the restored text lands in the cache with the new style too.
  ///
  /// No-op while disabled: there's no live filter, and the next
  /// `isEnabled = true` will instantiate one with the freshly-written vars.
  private func bustTextRenderCache() {
    guard isEnabled else { return }
    let text = player._marqueeText
    // Append a trailing space to force a different cache key. Invisible
    // controls like U+200B (ZWSP) don't alter the glyph sequence libVLC's
    // shaper produces, so they collapse to the same cache entry. Only a
    // visible-but-whitespace character reliably busts the cache.
    libvlc_video_set_marquee_string(pointer, UInt32(libvlc_marquee_Text.rawValue), text + " ")
    // Restore the original string on the next run-loop tick so the final
    // display shows the caller's exact text. 50 ms is enough for one
    // `spu_Render` cycle at 60 fps, which is what we need for the
    // intermediate text to lay down a fresh cache entry.
    let capturedPointer = pointer
    let capturedPlayer = player
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      libvlc_video_set_marquee_string(
        capturedPointer,
        UInt32(libvlc_marquee_Text.rawValue),
        capturedPlayer._marqueeText
      )
    }
  }
}
