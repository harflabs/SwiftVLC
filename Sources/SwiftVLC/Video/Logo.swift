import CLibVLC

/// Image overlay (logo) controls.
///
/// Access via `player.logo`:
/// ```swift
/// player.logo.isEnabled = true
/// player.logo.setFile("/path/to/logo.png")
/// player.logo.opacity = 200
/// ```
@MainActor
public struct Logo {
    private let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Whether the logo overlay is enabled.
    public var isEnabled: Bool {
        get { libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_enable.rawValue)) != 0 }
        nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_enable.rawValue), newValue ? 1 : 0) }
    }

    /// Sets the logo image file path.
    /// Format: "file" or "file,delay,transparency;file,delay,transparency;..."
    public nonmutating func setFile(_ path: String) {
        libvlc_video_set_logo_string(pointer, UInt32(libvlc_logo_file.rawValue), path)
    }

    /// X position offset.
    public var x: Int {
        get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_x.rawValue))) }
        nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_x.rawValue), Int32(newValue)) }
    }

    /// Y position offset.
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

    /// Position preset (see libvlc_position_t).
    public var position: Int {
        get { Int(libvlc_video_get_logo_int(pointer, UInt32(libvlc_logo_position.rawValue))) }
        nonmutating set { libvlc_video_set_logo_int(pointer, UInt32(libvlc_logo_position.rawValue), Int32(newValue)) }
    }
}
