import CLibVLC
import Darwin

/// Teletext color/action keys accepted by libVLC's teletext input API.
public enum TeletextKey: Sendable, Hashable {
  /// Selects the red teletext action.
  case red
  /// Selects the green teletext action.
  case green
  /// Selects the yellow teletext action.
  case yellow
  /// Selects the blue teletext action.
  case blue
  /// Requests the teletext index page.
  case index

  var cValue: Int32 {
    switch self {
    case .red: Int32(libvlc_teletext_key_red.rawValue)
    case .green: Int32(libvlc_teletext_key_green.rawValue)
    case .yellow: Int32(libvlc_teletext_key_yellow.rawValue)
    case .blue: Int32(libvlc_teletext_key_blue.rawValue)
    case .index: Int32(libvlc_teletext_key_index.rawValue)
    }
  }
}

/// Video overlay accessors and the 360°/VR viewpoint API.
extension Player {
  // MARK: - Video Adjustments

  /// Video color adjustments (contrast, brightness, hue, saturation, gamma).
  public var adjustments: VideoAdjustments {
    VideoAdjustments(player: self)
  }

  /// Scoped access to video adjustments for batched mutations.
  ///
  /// Prefer this over repeated `player.adjustments.x = ...` assignments
  /// when setting several values in sequence:
  /// ```swift
  /// player.withAdjustments { adj in
  ///     adj.isEnabled = true
  ///     adj.contrast = 1.2
  ///     adj.brightness = 1.1
  /// }
  /// ```
  public func withAdjustments<R>(_ body: (borrowing VideoAdjustments) throws -> R) rethrows -> R {
    let adj = VideoAdjustments(player: self)
    return try body(adj)
  }

  // MARK: - Marquee

  /// Text overlay (marquee) controls.
  public var marquee: Marquee {
    Marquee(player: self)
  }

  /// Scoped access to marquee controls for batch operations.
  ///
  /// ```swift
  /// player.withMarquee { m in
  ///     m.isEnabled = true
  ///     m.setText("Now Playing")
  ///     m.fontSize = 24
  /// }
  /// ```
  public func withMarquee<R>(_ body: (borrowing Marquee) throws -> R) rethrows -> R {
    let m = Marquee(player: self)
    return try body(m)
  }

  // MARK: - Logo

  /// Image overlay (logo) controls.
  public var logo: Logo {
    Logo(player: self)
  }

  /// Scoped access to logo controls for batch operations.
  ///
  /// ```swift
  /// player.withLogo { logo in
  ///     logo.isEnabled = true
  ///     logo.setFile("/path/to/logo.png")
  ///     logo.opacity = 200
  /// }
  /// ```
  public func withLogo<R>(_ body: (borrowing Logo) throws -> R) rethrows -> R {
    let l = Logo(player: self)
    return try body(l)
  }

  // MARK: - 360°/VR Viewpoint

  /// Updates the 360/VR video viewpoint.
  ///
  /// - Parameters:
  ///   - viewpoint: The new viewpoint values.
  ///   - absolute: If `true`, replaces the current viewpoint. If `false`, adjusts relative to current.
  /// - Throws: `VLCError.operationFailed` if the viewpoint cannot be applied.
  public func updateViewpoint(_ viewpoint: Viewpoint, absolute: Bool = true) throws(VLCError) {
    guard let vp = libvlc_video_new_viewpoint() else { throw .operationFailed("Allocate viewpoint") }
    defer { free(vp) }
    vp.pointee.f_yaw = viewpoint.yaw
    vp.pointee.f_pitch = viewpoint.pitch
    vp.pointee.f_roll = viewpoint.roll
    vp.pointee.f_field_of_view = viewpoint.fieldOfView
    guard libvlc_video_update_viewpoint(pointer, vp, absolute) == 0 else {
      throw .operationFailed("Update viewpoint")
    }
  }

  // MARK: - Teletext

  /// Current teletext page.
  ///
  /// libVLC initializes this to `100` (the standard teletext index page)
  /// regardless of whether the current media has a teletext track. To
  /// check whether teletext is actually available, inspect
  /// ``currentMedia`` and its tracks. Reading this value before any
  /// media is loaded returns `100`. Use ``setTeletextPage(_:)`` to change
  /// the page with integer range validation.
  public var teletextPage: Int {
    access(keyPath: \.teletextPage)
    return Int(libvlc_video_get_teletext(pointer))
  }

  /// Sets the current teletext page.
  ///
  /// Pass `0` to disable teletext, or a page in `1...999`.
  ///
  /// - Throws: ``VLCError/invalidInput(_:)`` if `page` is outside
  ///   libVLC's page domain.
  public func setTeletextPage(_ page: Int) throws(VLCError) {
    guard (0...999).contains(page) else {
      throw .invalidInput("teletext page must be 0 or in 1...999")
    }
    guard let page = Int32(exactly: page) else {
      throw .invalidInput("teletext page must fit in Int32")
    }
    withMutation(keyPath: \.teletextPage) {
      libvlc_video_set_teletext(pointer, page)
    }
  }

  /// Sends a teletext color/action key.
  public func sendTeletextKey(_ key: TeletextKey) {
    withMutation(keyPath: \.teletextPage) {
      libvlc_video_set_teletext(pointer, key.cValue)
    }
  }
}
