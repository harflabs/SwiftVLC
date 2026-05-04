/// Typed-value accessors that expose `Player`'s raw `Double`/`Float`
/// observations as `PlaybackPosition`, `Volume`, `PlaybackRate`, and
/// `SubtitleScale`. Mutations go through explicit methods so libVLC
/// rejection and invalid state are not silently discarded by property
/// writes.
///
/// ```swift
/// try player.seek(to: .end)
/// try player.setAudioVolume(.muted)
/// try player.setPlaybackRate(.double)
/// ```
extension Player {
  /// Fractional playback position, clamped to `0.0 ... 1.0`.
  ///
  /// Use ``seek(to:)-(PlaybackPosition)`` to change the position with validation.
  public var playbackPosition: PlaybackPosition {
    PlaybackPosition(position)
  }

  /// Audio output volume, clamped to `0.0 ... 1.25`.
  ///
  /// Use ``setAudioVolume(_:)`` to change volume.
  public var audioVolume: Volume {
    Volume(volume)
  }

  /// Playback rate, clamped to `0.25 ... 4.0`.
  ///
  /// Use ``setPlaybackRate(_:)`` to request a new rate.
  public var playbackRate: PlaybackRate {
    PlaybackRate(rate)
  }

  /// Subtitle text scale, clamped to `0.1 ... 5.0`.
  ///
  /// Use ``setSubtitleScale(_:)`` to change scale.
  public var subtitleScale: SubtitleScale {
    SubtitleScale(subtitleTextScale)
  }

  /// Sets the playback rate with rejection awareness.
  ///
  /// libVLC may reject rate changes for some media (e.g. live streams).
  /// The throwing variant lets callers distinguish "rejected" from
  /// "applied".
  public func setPlaybackRate(_ newRate: PlaybackRate) throws(VLCError) {
    try setRate(newRate)
  }
}
