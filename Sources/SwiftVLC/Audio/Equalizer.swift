import CLibVLC

/// A 10-band audio equalizer with preamp and preset support.
///
/// Create an equalizer, configure it, then apply to a player:
/// ```swift
/// let eq = Equalizer()
/// eq.preamp = 5.0
/// eq.setAmplification(10.0, forBand: 0)
/// player.setEqualizer(eq)
/// ```
public final class Equalizer: Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_equalizer_t*

    /// Creates a new equalizer with flat (0 dB) settings.
    public init() {
        pointer = libvlc_audio_equalizer_new()!
    }

    /// Creates an equalizer from a preset.
    /// - Parameter presetIndex: Index of the preset (0 ..< `presetCount`).
    public init(preset presetIndex: UInt32) {
        pointer = libvlc_audio_equalizer_new_from_preset(presetIndex)!
    }

    deinit {
        libvlc_audio_equalizer_release(pointer)
    }

    // MARK: - Preamp

    /// Preamp gain in dB (-20.0 to +20.0).
    public var preamp: Float {
        get { libvlc_audio_equalizer_get_preamp(pointer) }
        set { libvlc_audio_equalizer_set_preamp(pointer, newValue) }
    }

    // MARK: - Bands

    /// Number of frequency bands.
    public static var bandCount: UInt32 {
        libvlc_audio_equalizer_get_band_count()
    }

    /// Gets the center frequency (Hz) for a band.
    public static func bandFrequency(at index: UInt32) -> Float {
        libvlc_audio_equalizer_get_band_frequency(index)
    }

    /// Gets the amplification for a specific band.
    public func amplification(forBand band: UInt32) -> Float {
        libvlc_audio_equalizer_get_amp_at_index(pointer, band)
    }

    /// Sets the amplification for a specific band (-20.0 to +20.0 dB).
    @discardableResult
    public func setAmplification(_ amp: Float, forBand band: UInt32) -> Bool {
        libvlc_audio_equalizer_set_amp_at_index(pointer, amp, band) == 0
    }

    // MARK: - Presets

    /// Number of available presets.
    public static var presetCount: UInt32 {
        libvlc_audio_equalizer_get_preset_count()
    }

    /// Name of a preset at the given index.
    public static func presetName(at index: UInt32) -> String? {
        libvlc_audio_equalizer_get_preset_name(index).map { String(cString: $0) }
    }

    /// All available preset names.
    public static var presetNames: [String] {
        (0 ..< presetCount).compactMap { presetName(at: $0) }
    }
}
