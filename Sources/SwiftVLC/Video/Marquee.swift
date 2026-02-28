import CLibVLC

/// Text overlay (marquee) controls.
///
/// Access via `player.marquee`:
/// ```swift
/// player.marquee.isEnabled = true
/// player.marquee.text = "Now Playing"
/// player.marquee.fontSize = 24
/// ```
@MainActor
public struct Marquee {
    private let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Whether the marquee overlay is enabled.
    public var isEnabled: Bool {
        get { libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Enable.rawValue)) != 0 }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Enable.rawValue), newValue ? 1 : 0) }
    }

    /// Marquee text content.
    public nonmutating func setText(_ text: String) {
        libvlc_video_set_marquee_string(pointer, UInt32(libvlc_marquee_Text.rawValue), text)
    }

    /// Text color as an RGB integer (e.g. 0xFF0000 for red).
    public var color: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Color.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Color.rawValue), Int32(newValue)) }
    }

    /// Text opacity (0-255).
    public var opacity: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Opacity.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Opacity.rawValue), Int32(newValue)) }
    }

    /// Font size in pixels.
    public var fontSize: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Size.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Size.rawValue), Int32(newValue)) }
    }

    /// X position offset.
    public var x: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_X.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_X.rawValue), Int32(newValue)) }
    }

    /// Y position offset.
    public var y: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Y.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Y.rawValue), Int32(newValue)) }
    }

    /// Timeout in milliseconds (0 for permanent).
    public var timeout: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Timeout.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Timeout.rawValue), Int32(newValue)) }
    }

    /// Refresh interval in milliseconds.
    public var refresh: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Refresh.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Refresh.rawValue), Int32(newValue)) }
    }

    /// Position preset (see libvlc_position_t).
    public var position: Int {
        get { Int(libvlc_video_get_marquee_int(pointer, UInt32(libvlc_marquee_Position.rawValue))) }
        nonmutating set { libvlc_video_set_marquee_int(pointer, UInt32(libvlc_marquee_Position.rawValue), Int32(newValue)) }
    }
}
