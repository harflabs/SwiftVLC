// MARK: - PlaybackPosition

/// A fractional position in the current media, in `0.0 ... 1.0`.
///
/// Assigning through `Player.playbackPosition` clamps values outside
/// this range to the nearest endpoint rather than silently
/// misbehaving.
///
/// ```swift
/// player.playbackPosition = .end          // 1.0
/// player.playbackPosition = 0.5           // half-way
/// player.playbackPosition = .init(2.0)    // clamped to 1.0
/// ```
public struct PlaybackPosition: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral {
  /// The clamped value, in `0.0 ... 1.0`.
  public let rawValue: Double

  /// Creates a position, clamping to `0.0 ... 1.0`.
  public init(_ value: Double) {
    rawValue = Swift.max(0.0, Swift.min(1.0, value))
  }

  /// `ExpressibleByFloatLiteral` conformance — `player.playbackPosition = 0.5`.
  public init(floatLiteral value: Double) {
    self.init(value)
  }

  /// Position 0.0 (start of media).
  public static let zero: PlaybackPosition = 0.0
  /// Position 1.0 (end of media).
  public static let end: PlaybackPosition = 1.0

  public static func < (lhs: PlaybackPosition, rhs: PlaybackPosition) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

// MARK: - Volume

/// Audio output volume, in `0.0 ... 1.25` (silent through 125%).
///
/// libVLC accepts amplification above 1.0 up to its internal ceiling;
/// the SwiftVLC clamp of 1.25 reflects the practical headroom before
/// audio clipping becomes audible on most outputs.
///
/// ```swift
/// player.audioVolume = .muted          // 0.0
/// player.audioVolume = .unity          // 1.0 (default)
/// player.audioVolume = 0.8             // 80 %
/// player.audioVolume = .init(2.0)      // clamped to 1.25
/// ```
public struct Volume: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral {
  /// The clamped value, in `0.0 ... 1.25`.
  public let rawValue: Float

  /// Creates a volume, clamping to `0.0 ... 1.25`.
  public init(_ value: Float) {
    rawValue = Swift.max(0.0, Swift.min(1.25, value))
  }

  /// `ExpressibleByFloatLiteral` conformance — `player.audioVolume = 0.8`.
  public init(floatLiteral value: Double) {
    self.init(Float(value))
  }

  /// Volume 0.0 (silent).
  public static let muted: Volume = 0.0
  /// Volume 1.0 (default unity gain, 100%).
  public static let unity: Volume = 1.0
  /// Volume 1.25 (the maximum SwiftVLC will pass to libVLC).
  public static let max: Volume = 1.25

  public static func < (lhs: Volume, rhs: Volume) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

// MARK: - PlaybackRate

/// Playback rate as a multiplier of normal speed.
///
/// Range is `0.25 ... 4.0`. libVLC accepts values outside this range
/// for some media but audio/video sync degrades; SwiftVLC clamps to
/// keep observable behavior predictable.
///
/// Live streams (HLS, RTSP) often reject any rate other than `1.0`.
/// Use `Player.setRate(_:)` instead of this property when the UI must
/// react to that rejection.
///
/// ```swift
/// player.playbackRate = .normal           // 1.0
/// player.playbackRate = .double           // 2.0
/// player.playbackRate = .half             // 0.5
/// player.playbackRate = 1.25              // any value in 0.25 ... 4.0
/// ```
public struct PlaybackRate: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral {
  /// The clamped value, in `0.25 ... 4.0`.
  public let rawValue: Float

  /// Creates a rate, clamping to `0.25 ... 4.0`.
  public init(_ value: Float) {
    rawValue = Swift.max(0.25, Swift.min(4.0, value))
  }

  /// `ExpressibleByFloatLiteral` conformance — `player.playbackRate = 1.5`.
  public init(floatLiteral value: Double) {
    self.init(Float(value))
  }

  /// Rate 1.0 (normal speed).
  public static let normal: PlaybackRate = 1.0
  /// Rate 0.5 (half speed).
  public static let half: PlaybackRate = 0.5
  /// Rate 2.0 (double speed).
  public static let double: PlaybackRate = 2.0
  /// Rate 0.25 (the minimum SwiftVLC will pass to libVLC).
  public static let slowest: PlaybackRate = 0.25
  /// Rate 4.0 (the maximum SwiftVLC will pass to libVLC).
  public static let fastest: PlaybackRate = 4.0

  public static func < (lhs: PlaybackRate, rhs: PlaybackRate) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

// MARK: - SubtitleScale

/// Subtitle text scale factor, in `0.1 ... 5.0` (10 % to 500 %).
///
/// libVLC clamps internally to this range; the SwiftVLC wrapper makes
/// the clamp visible at the type level so callers can't accidentally
/// pass `0` (invisible subtitles) or a negative value.
///
/// ```swift
/// player.subtitleScale = .normal            // 1.0 (default)
/// player.subtitleScale = .doubleSize        // 2.0
/// player.subtitleScale = 1.5                // any value in 0.1 ... 5.0
/// ```
public struct SubtitleScale: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral {
  /// The clamped value, in `0.1 ... 5.0`.
  public let rawValue: Float

  /// Creates a scale, clamping to `0.1 ... 5.0`.
  public init(_ value: Float) {
    rawValue = Swift.max(0.1, Swift.min(5.0, value))
  }

  /// `ExpressibleByFloatLiteral` conformance — `player.subtitleScale = 1.5`.
  public init(floatLiteral value: Double) {
    self.init(Float(value))
  }

  /// Scale 1.0 (100 %, default).
  public static let normal: SubtitleScale = 1.0
  /// Scale 0.5 (50 %).
  public static let halfSize: SubtitleScale = 0.5
  /// Scale 2.0 (200 %).
  public static let doubleSize: SubtitleScale = 2.0

  public static func < (lhs: SubtitleScale, rhs: SubtitleScale) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

// MARK: - EqualizerGain

/// A dB-gain value used by ``Equalizer`` for the preamp and per-band
/// amplification. Range is `-20.0 ... +20.0` dB; libVLC clamps any
/// value outside that window.
///
/// ```swift
/// equalizer.preampGain = .flat              // 0 dB
/// equalizer.preampGain = +5.0               // any value in -20 ... +20
/// equalizer.preampGain = .init(+30)         // clamped to +20
/// ```
public struct EqualizerGain: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral {
  /// The clamped value, in `-20.0 ... +20.0` dB.
  public let rawValue: Float

  /// Creates a gain, clamping to `-20.0 ... +20.0`.
  public init(_ value: Float) {
    rawValue = Swift.max(-20.0, Swift.min(20.0, value))
  }

  /// `ExpressibleByFloatLiteral` conformance — `gain = 6.0`.
  public init(floatLiteral value: Double) {
    self.init(Float(value))
  }

  /// 0 dB (no boost or cut).
  public static let flat: EqualizerGain = 0.0
  /// −20 dB (the minimum SwiftVLC will pass to libVLC).
  public static let minimum: EqualizerGain = -20.0
  /// +20 dB (the maximum SwiftVLC will pass to libVLC).
  public static let maximum: EqualizerGain = 20.0

  public static func < (lhs: EqualizerGain, rhs: EqualizerGain) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
