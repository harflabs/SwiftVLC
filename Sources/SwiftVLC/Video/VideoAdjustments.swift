import CLibVLC

/// Video color adjustment controls (contrast, brightness, hue, saturation, gamma).
///
/// Access via `player.adjustments`:
/// ```swift
/// player.adjustments.isEnabled = true
/// player.adjustments.contrast = 1.2
/// player.adjustments.brightness = 1.1
/// ```
@MainActor
public struct VideoAdjustments {
    private let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Whether video adjustments are enabled.
    public var isEnabled: Bool {
        get { libvlc_video_get_adjust_int(pointer, UInt32(libvlc_adjust_Enable.rawValue)) != 0 }
        nonmutating set { libvlc_video_set_adjust_int(pointer, UInt32(libvlc_adjust_Enable.rawValue), newValue ? 1 : 0) }
    }

    /// Contrast (0.0 to 2.0, default 1.0).
    public var contrast: Float {
        get { libvlc_video_get_adjust_float(pointer, UInt32(libvlc_adjust_Contrast.rawValue)) }
        nonmutating set { libvlc_video_set_adjust_float(pointer, UInt32(libvlc_adjust_Contrast.rawValue), newValue) }
    }

    /// Brightness (0.0 to 2.0, default 1.0).
    public var brightness: Float {
        get { libvlc_video_get_adjust_float(pointer, UInt32(libvlc_adjust_Brightness.rawValue)) }
        nonmutating set { libvlc_video_set_adjust_float(pointer, UInt32(libvlc_adjust_Brightness.rawValue), newValue) }
    }

    /// Hue (0 to 360 degrees, default 0).
    public var hue: Float {
        get { libvlc_video_get_adjust_float(pointer, UInt32(libvlc_adjust_Hue.rawValue)) }
        nonmutating set { libvlc_video_set_adjust_float(pointer, UInt32(libvlc_adjust_Hue.rawValue), newValue) }
    }

    /// Saturation (0.0 to 3.0, default 1.0).
    public var saturation: Float {
        get { libvlc_video_get_adjust_float(pointer, UInt32(libvlc_adjust_Saturation.rawValue)) }
        nonmutating set { libvlc_video_set_adjust_float(pointer, UInt32(libvlc_adjust_Saturation.rawValue), newValue) }
    }

    /// Gamma (0.01 to 10.0, default 1.0).
    public var gamma: Float {
        get { libvlc_video_get_adjust_float(pointer, UInt32(libvlc_adjust_Gamma.rawValue)) }
        nonmutating set { libvlc_video_set_adjust_float(pointer, UInt32(libvlc_adjust_Gamma.rawValue), newValue) }
    }
}
