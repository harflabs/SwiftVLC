import CLibVLC
import Observation

/// A 10-band audio equalizer with preamp and preset support.
///
/// `Equalizer` is `@Observable` and `@MainActor`. SwiftUI views that
/// read ``preamp`` or ``bands`` update automatically, and the player
/// it is attached to re-applies its audio output on every change.
///
/// ```swift
/// let eq = Equalizer()
/// eq.preampGain = 5.0
/// try eq.setAmplification(10.0, forBand: 0)
/// player.equalizer = eq
/// ```
@Observable
@MainActor
public final class Equalizer {
  @ObservationIgnored
  let pointer: OpaquePointer // libvlc_equalizer_t*

  /// Fires on the main actor after any observable change. `Player`
  /// installs a handler here on assignment to re-apply the equalizer to
  /// its audio output, since libVLC copies settings on
  /// `libvlc_media_player_set_equalizer` and does not retain the reference.
  @ObservationIgnored
  var onChange: (@MainActor () -> Void)?

  /// Creates a new equalizer with flat (0 dB) settings.
  public init() {
    guard let p = libvlc_audio_equalizer_new() else {
      preconditionFailure("Failed to allocate libvlc equalizer. Out of memory?")
    }
    pointer = p
  }

  /// Creates an equalizer from a preset.
  /// - Parameter presetIndex: Index of the preset (0 ..< `presetCount`).
  /// - Returns: `nil` if `presetIndex` is invalid.
  public init?(preset presetIndex: Int) {
    guard presetIndex >= 0 && presetIndex < Self.presetCount else {
      return nil
    }
    guard let presetIndex = UInt32(exactly: presetIndex) else { return nil }
    guard let p = libvlc_audio_equalizer_new_from_preset(presetIndex) else {
      preconditionFailure("Failed to allocate libvlc equalizer for preset \(presetIndex). Out of memory?")
    }
    pointer = p
  }

  isolated deinit {
    libvlc_audio_equalizer_release(pointer)
  }

  // MARK: - Preamp

  /// Preamp gain applied ahead of the per-band amplification, in dB.
  ///
  /// Use ``preampGain`` to mutate this value through the typed
  /// ``EqualizerGain`` range.
  public var preamp: Float {
    access(keyPath: \.preamp)
    return libvlc_audio_equalizer_get_preamp(pointer)
  }

  // MARK: - Bands

  /// Number of frequency bands.
  public static var bandCount: Int {
    Int(libvlc_audio_equalizer_get_band_count())
  }

  /// Returns the center frequency (Hz) for a band.
  /// - Parameter index: Band index (0 ..< ``bandCount``).
  /// - Returns: The band frequency, or `nil` if `index` is invalid.
  public static func bandFrequency(at index: Int) -> Float? {
    guard index >= 0 && index < bandCount, let index = UInt32(exactly: index) else {
      return nil
    }
    return libvlc_audio_equalizer_get_band_frequency(index)
  }

  /// Per-band amplification in dB, in frequency order. The array length
  /// always equals ``bandCount``.
  ///
  /// Reading takes a snapshot of the current band values. Use
  /// ``setBands(_:)`` to write values with length validation.
  public var bands: [Float] {
    access(keyPath: \.bands)
    return (0..<Self.bandCount).map {
      libvlc_audio_equalizer_get_amp_at_index(pointer, UInt32($0))
    }
  }

  /// Sets all per-band amplification values.
  ///
  /// - Parameter bands: One value per equalizer band.
  /// - Throws: ``VLCError/invalidInput(_:)`` when `bands.count` does not
  ///   equal ``bandCount``.
  public func setBands(_ bands: [Float]) throws(VLCError) {
    guard bands.count == Self.bandCount else {
      throw .invalidInput("bands.count must equal Equalizer.bandCount (\(Self.bandCount))")
    }
    let current = (0..<Self.bandCount).map {
      libvlc_audio_equalizer_get_amp_at_index(pointer, UInt32($0))
    }
    guard current != bands else { return }
    withMutation(keyPath: \.bands) {
      for (index, amp) in bands.enumerated() where current[index] != amp {
        libvlc_audio_equalizer_set_amp_at_index(pointer, amp, UInt32(index))
      }
    }
    onChange?()
  }

  /// Returns the amplification (dB) for a specific band.
  /// - Parameter band: Band index (0 ..< ``bandCount``).
  /// - Returns: The amplification value, or `nil` if `band` is invalid.
  public func amplification(forBand band: Int) -> Float? {
    access(keyPath: \.bands)
    guard band >= 0 && band < Self.bandCount, let band = UInt32(exactly: band) else {
      return nil
    }
    return libvlc_audio_equalizer_get_amp_at_index(pointer, band)
  }

  /// Sets the amplification for a specific band (-20.0 to +20.0 dB).
  /// - Throws: ``VLCError/invalidInput(_:)`` if the band index is invalid,
  ///   or ``VLCError/operationFailed(_:)`` if libVLC rejects the value.
  public func setAmplification(_ amp: Float, forBand band: Int) throws(VLCError) {
    guard band >= 0 && band < Self.bandCount else {
      throw .invalidInput("band must be in 0..<\(Self.bandCount)")
    }
    let band = try checkedUInt32(band, parameter: "band")
    guard libvlc_audio_equalizer_set_amp_at_index(pointer, amp, band) == 0 else {
      throw .operationFailed("Set equalizer amplification for band \(band)")
    }
    withMutation(keyPath: \.bands) {}
    onChange?()
  }

  // MARK: - Presets

  /// Number of available presets.
  public static var presetCount: Int {
    Int(libvlc_audio_equalizer_get_preset_count())
  }

  /// Returns the name of a preset at the given index, or `nil` if the index is invalid.
  public static func presetName(at index: Int) -> String? {
    guard index >= 0 && index < presetCount else { return nil }
    guard let index = UInt32(exactly: index) else { return nil }
    return libvlc_audio_equalizer_get_preset_name(index).map { String(cString: $0) }
  }

  /// All available preset names.
  public static var presetNames: [String] {
    (0..<presetCount).compactMap { presetName(at: $0) }
  }
}

// MARK: - Typed-gain accessors

/// Typed-gain accessors that wrap ``Equalizer``'s raw `Float`
/// properties in ``EqualizerGain``, clamping to libVLC's
/// `-20.0 ... +20.0` dB range at the type level.
///
/// ```swift
/// equalizer.preampGain = .flat
/// try equalizer.setBandGains([+3.0, +2.0, .flat, -1.0, -2.0, -2.0, -1.0, .flat, +1.0, +2.0])
/// try equalizer.setGain(+6.0, forBand: 3)
/// ```
extension Equalizer {
  /// Preamp gain, clamped to `-20.0 ... +20.0` dB.
  ///
  /// Assign to this property to mutate the preamp through the typed
  /// ``EqualizerGain`` range. Read ``preamp`` when you need the raw
  /// `Float` value libVLC currently reports.
  public var preampGain: EqualizerGain {
    get { EqualizerGain(preamp) }
    set { applyPreamp(newValue.rawValue) }
  }

  /// Per-band amplification, each clamped to `-20.0 ... +20.0` dB.
  /// Use ``setBandGains(_:)`` to write values with length validation.
  public var bandGains: [EqualizerGain] {
    bands.map(EqualizerGain.init)
  }

  /// Sets all typed per-band gain values.
  ///
  /// - Throws: ``VLCError/invalidInput(_:)`` when `gains.count` does not
  ///   equal ``bandCount``.
  public func setBandGains(_ gains: [EqualizerGain]) throws(VLCError) {
    try setBands(gains.map(\.rawValue))
  }

  /// Returns the typed gain for a specific band.
  /// - Parameter band: Band index (0 ..< ``bandCount``).
  /// - Returns: The band gain, or `nil` if `band` is invalid.
  public func gain(forBand band: Int) -> EqualizerGain? {
    amplification(forBand: band).map(EqualizerGain.init)
  }

  /// Sets the typed gain for a specific band.
  /// - Throws: ``VLCError/invalidInput(_:)`` if the band index is invalid,
  ///   or ``VLCError/operationFailed(_:)`` if libVLC rejects the value.
  public func setGain(_ gain: EqualizerGain, forBand band: Int) throws(VLCError) {
    try setAmplification(gain.rawValue, forBand: band)
  }

  private func applyPreamp(_ newValue: Float) {
    guard libvlc_audio_equalizer_get_preamp(pointer) != newValue else { return }
    _ = withMutation(keyPath: \.preamp) {
      libvlc_audio_equalizer_set_preamp(pointer, newValue)
    }
    onChange?()
  }
}
