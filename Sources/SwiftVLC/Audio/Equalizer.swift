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
/// eq.preamp = 5.0
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
  /// - Precondition: `presetIndex` must be in `0 ..< presetCount`.
  public init(preset presetIndex: Int) {
    precondition(presetIndex >= 0 && presetIndex < Self.presetCount, "Invalid preset index \(presetIndex)")
    guard let p = libvlc_audio_equalizer_new_from_preset(UInt32(presetIndex)) else {
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
  /// Valid range is `-20.0` to `+20.0`; libVLC clamps values outside
  /// that window.
  public var preamp: Float {
    get {
      access(keyPath: \.preamp)
      return libvlc_audio_equalizer_get_preamp(pointer)
    }
    set {
      guard libvlc_audio_equalizer_get_preamp(pointer) != newValue else { return }
      _ = withMutation(keyPath: \.preamp) {
        libvlc_audio_equalizer_set_preamp(pointer, newValue)
      }
      onChange?()
    }
  }

  // MARK: - Bands

  /// Number of frequency bands.
  public static var bandCount: Int {
    Int(libvlc_audio_equalizer_get_band_count())
  }

  /// Returns the center frequency (Hz) for a band.
  /// - Parameter index: Band index (0 ..< ``bandCount``).
  /// - Precondition: `index` must be in `0 ..< bandCount`.
  public static func bandFrequency(at index: Int) -> Float {
    precondition(index >= 0 && index < bandCount, "Band index \(index) out of range (0 ..< \(bandCount))")
    return libvlc_audio_equalizer_get_band_frequency(UInt32(index))
  }

  /// Per-band amplification in dB, in frequency order. The array length
  /// always equals ``bandCount``.
  ///
  /// Reading takes a snapshot of the current band values. Assigning a
  /// new array writes each element through to libVLC and triggers
  /// re-application on the attached player. Assigning an array of the
  /// wrong length traps.
  public var bands: [Float] {
    get {
      access(keyPath: \.bands)
      return (0..<Self.bandCount).map {
        libvlc_audio_equalizer_get_amp_at_index(pointer, UInt32($0))
      }
    }
    set {
      precondition(
        newValue.count == Self.bandCount,
        "bands.count (\(newValue.count)) must equal Equalizer.bandCount (\(Self.bandCount))"
      )
      let current = (0..<Self.bandCount).map {
        libvlc_audio_equalizer_get_amp_at_index(pointer, UInt32($0))
      }
      guard current != newValue else { return }
      withMutation(keyPath: \.bands) {
        for (index, amp) in newValue.enumerated() where current[index] != amp {
          libvlc_audio_equalizer_set_amp_at_index(pointer, amp, UInt32(index))
        }
      }
      onChange?()
    }
  }

  /// Returns the amplification (dB) for a specific band.
  /// - Parameter band: Band index (0 ..< ``bandCount``).
  /// - Precondition: `band` must be in `0 ..< bandCount`.
  public func amplification(forBand band: Int) -> Float {
    precondition(band >= 0 && band < Self.bandCount, "Band index \(band) out of range (0 ..< \(Self.bandCount))")
    access(keyPath: \.bands)
    return libvlc_audio_equalizer_get_amp_at_index(pointer, UInt32(band))
  }

  /// Sets the amplification for a specific band (-20.0 to +20.0 dB).
  /// - Throws: `VLCError.operationFailed` if the band index is invalid.
  public func setAmplification(_ amp: Float, forBand band: Int) throws(VLCError) {
    guard band >= 0 && band < Self.bandCount else {
      throw .operationFailed("Set equalizer amplification for band \(band)")
    }
    guard libvlc_audio_equalizer_set_amp_at_index(pointer, amp, UInt32(band)) == 0 else {
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
    return libvlc_audio_equalizer_get_preset_name(UInt32(index)).map { String(cString: $0) }
  }

  /// All available preset names.
  public static var presetNames: [String] {
    (0..<presetCount).compactMap { presetName(at: $0) }
  }
}
