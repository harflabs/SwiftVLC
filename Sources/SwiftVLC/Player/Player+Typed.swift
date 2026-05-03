/// Typed-value accessors that wrap `Player`'s raw `Double`/`Float`
/// properties in `PlaybackPosition`, `Volume`, `PlaybackRate`, and
/// `SubtitleScale` — each clamps to its valid range on construction.
///
/// ```swift
/// player.playbackPosition = .end       // clearer than `player.position = 1.0`
/// player.audioVolume = .muted          // clearer than `player.volume = 0`
/// player.playbackRate = .double        // clearer than `player.rate = 2.0`
/// ```
extension Player {
  /// Fractional playback position, clamped to `0.0 ... 1.0`.
  ///
  /// Setting this seeks. Prefer this over the raw ``position`` property
  /// when you want compile-time clamping and the `.zero` / `.end`
  /// shorthands.
  public var playbackPosition: PlaybackPosition {
    get { PlaybackPosition(position) }
    set { position = newValue.rawValue }
  }

  /// Audio output volume, clamped to `0.0 ... 1.25`.
  ///
  /// Prefer this over the raw ``volume`` property when you want
  /// compile-time clamping and the `.muted` / `.unity` shorthands.
  public var audioVolume: Volume {
    get { Volume(volume) }
    set { volume = newValue.rawValue }
  }

  /// Playback rate, clamped to `0.25 ... 4.0`.
  ///
  /// Prefer this over the raw ``rate`` property when you want
  /// compile-time clamping and the `.normal` / `.half` / `.double`
  /// shorthands. For rejection-aware rate changes use ``setRate(_:)``.
  public var playbackRate: PlaybackRate {
    get { PlaybackRate(rate) }
    set { rate = newValue.rawValue }
  }

  /// Subtitle text scale, clamped to `0.1 ... 5.0`.
  ///
  /// Prefer this over the raw ``subtitleTextScale`` property when you
  /// want compile-time clamping and the `.normal` / `.halfSize` /
  /// `.doubleSize` shorthands.
  public var subtitleScale: SubtitleScale {
    get { SubtitleScale(subtitleTextScale) }
    set { subtitleTextScale = newValue.rawValue }
  }

  /// Sets the playback rate with rejection awareness.
  ///
  /// libVLC may reject rate changes for some media (e.g. live streams).
  /// The throwing variant lets callers distinguish "rejected" from
  /// "applied", whereas assigning to ``playbackRate`` silently no-ops on
  /// rejection.
  public func setPlaybackRate(_ newRate: PlaybackRate) throws(VLCError) {
    try setRate(newRate.rawValue)
  }
}
