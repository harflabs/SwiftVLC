import CLibVLC

/// A 10-band audio equalizer with preamp and preset support.
///
/// Create an equalizer, configure it, then apply to a player:
/// ```swift
/// let eq = Equalizer()
/// eq.preamp = 5.0
/// try eq.setAmplification(10.0, forBand: 0)
/// player.equalizer = eq
/// ```
@MainActor
public final class Equalizer {
  let pointer: OpaquePointer // libvlc_equalizer_t*

  /// Creates a new equalizer with flat (0 dB) settings.
  public init() {
    pointer = libvlc_audio_equalizer_new()!
  }

  /// Creates an equalizer from a preset.
  /// - Parameter presetIndex: Index of the preset (0 ..< `presetCount`).
  /// - Precondition: `presetIndex` must be in `0 ..< presetCount`.
  public init(preset presetIndex: Int) {
    precondition(presetIndex >= 0 && presetIndex < Self.presetCount, "Invalid preset index \(presetIndex)")
    pointer = libvlc_audio_equalizer_new_from_preset(UInt32(presetIndex))!
  }

  isolated deinit {
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
  public static var bandCount: Int {
    Int(libvlc_audio_equalizer_get_band_count())
  }

  /// Returns the center frequency (Hz) for a band.
  /// - Parameter index: Band index (0 ..< ``bandCount``).
  public static func bandFrequency(at index: Int) -> Float {
    libvlc_audio_equalizer_get_band_frequency(UInt32(index))
  }

  /// Returns the amplification (dB) for a specific band.
  /// - Parameter band: Band index (0 ..< ``bandCount``).
  public func amplification(forBand band: Int) -> Float {
    libvlc_audio_equalizer_get_amp_at_index(pointer, UInt32(band))
  }

  /// Sets the amplification for a specific band (-20.0 to +20.0 dB).
  /// - Throws: `VLCError.operationFailed` if the band index is invalid.
  public func setAmplification(_ amp: Float, forBand band: Int) throws(VLCError) {
    guard libvlc_audio_equalizer_set_amp_at_index(pointer, amp, UInt32(band)) == 0 else {
      throw .operationFailed("Set equalizer amplification for band \(band)")
    }
  }

  // MARK: - Presets

  /// Number of available presets.
  public static var presetCount: Int {
    Int(libvlc_audio_equalizer_get_preset_count())
  }

  /// Returns the name of a preset at the given index, or `nil` if the index is invalid.
  public static func presetName(at index: Int) -> String? {
    libvlc_audio_equalizer_get_preset_name(UInt32(index)).map { String(cString: $0) }
  }

  /// All available preset names.
  public static var presetNames: [String] {
    (0..<presetCount).compactMap { presetName(at: $0) }
  }
}
