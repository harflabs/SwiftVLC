#if os(iOS) || os(macOS)

import CoreMedia

extension PiPController {
  /// The duration of one frame at the selected video track's own cadence, or
  /// `nil` when no track reports one.
  ///
  /// Prefers the selected track, since that is the one being decoded; falls
  /// back to any video track that reports a cadence, because a track list can
  /// briefly show nothing selected right after a media change.
  ///
  /// Returns `nil` rather than a default. Direct PiP used to stamp every frame
  /// with exactly `1/30s` regardless of the source, which misdescribes 24, 25,
  /// 50 and 60 fps content and every variable-frame-rate stream. Sample
  /// duration is not decorative — AVFoundation uses it for scheduling, pacing
  /// and backpressure — and a fabricated value is worse than none, because
  /// nothing downstream can tell it was fabricated.
  @MainActor
  static func sourceFrameDuration(of player: Player) -> CMTime? {
    let tracks = player.videoTracks
    let ratio = tracks.first(where: { $0.isSelected })?.frameRateRatio
      ?? tracks.lazy.compactMap(\.frameRateRatio).first
    guard let ratio else { return nil }
    return PixelBufferRenderer.frameDuration(
      rateNumerator: ratio.numerator,
      rateDenominator: ratio.denominator
    )
  }
}

#endif
