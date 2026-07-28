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
    let ratio: FrameRateRatio? = if let selected = tracks.first(where: \.isSelected) {
      // The selected track is the one being decoded. If it reports no cadence,
      // the answer is "unknown" — borrowing a sibling track's rate would be
      // fabrication of a subtler kind than the 30 fps default this replaces.
      selected.frameRateRatio
    } else {
      // Nothing selected yet, which a track list shows briefly right after a
      // media change. Any track that reports a cadence is better than none.
      tracks.lazy.compactMap(\.frameRateRatio).first
    }
    guard let ratio else { return nil }
    return PixelBufferRenderer.frameDuration(
      rateNumerator: ratio.numerator,
      rateDenominator: ratio.denominator
    )
  }
}

#endif
