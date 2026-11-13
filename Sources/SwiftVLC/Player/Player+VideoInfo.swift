import CLibVLC
import CoreGraphics

/// Decoded video size and selected-video-track presence.
extension Player {
  /// Decoded size of the currently selected video track, in pixels.
  ///
  /// Read live from libVLC's track list: `libvlc_video_get_size` reports
  /// the selected video track's decoded dimensions, without touching a
  /// video output. `nil` while no video track is selected — audio-only
  /// media, an idle player — or before the decoder has published a
  /// non-zero size. Observers are re-signaled when the output count
  /// changes and on track changes, which covers adaptive streams that
  /// switch resolution mid-stream without any dedicated size event.
  public var videoSize: CGSize? {
    access(keyPath: \.videoSize)
    guard nativeHandleRepresentsCurrentMedia else { return nil }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readVideoSize)
    #endif
    var width: UInt32 = 0
    var height: UInt32 = 0
    guard
      libvlc_video_get_size(pointer, 0, &width, &height) == 0,
      width > 0, height > 0
    else { return nil }
    return CGSize(width: Int(width), height: Int(height))
  }

  /// The size the selected video track is meant to be displayed at:
  /// ``videoSize`` with the track's sample aspect ratio and rotation applied.
  ///
  /// ``videoSize`` counts stored pixels. Anamorphic video (a 720x576 picture
  /// shown at 16:9) and video recorded in portrait with a rotation flag have
  /// a different shape on screen, which is what a window or a Picture in
  /// Picture panel has to match. `nil` whenever ``videoSize`` is.
  var videoDisplaySize: CGSize? {
    access(keyPath: \.videoSize)
    #if DEBUG
    if let override = _videoDisplaySizeOverrideForTesting {
      return override
    }
    #endif
    guard nativeHandleRepresentsCurrentMedia, let track = libvlc_media_player_get_selected_track(pointer, libvlc_track_video) else {
      return nil
    }
    defer { libvlc_media_track_release(track) }
    guard let video = track.pointee.video?.pointee, video.i_width > 0, video.i_height > 0 else {
      return nil
    }
    return Self.displaySize(
      width: video.i_width,
      height: video.i_height,
      sampleAspectRatio: (video.i_sar_num, video.i_sar_den),
      orientation: video.i_orientation
    )
  }

  nonisolated static func displaySize(
    width: UInt32,
    height: UInt32,
    sampleAspectRatio: (numerator: UInt32, denominator: UInt32),
    orientation: libvlc_video_orient_t
  ) -> CGSize {
    var displayWidth = Double(width)
    let displayHeight = Double(height)
    // A missing ratio (0:0) means square pixels.
    if sampleAspectRatio.numerator > 0, sampleAspectRatio.denominator > 0 {
      displayWidth *= Double(sampleAspectRatio.numerator) / Double(sampleAspectRatio.denominator)
    }
    switch orientation {
    case libvlc_video_orient_left_top, libvlc_video_orient_left_bottom,
         libvlc_video_orient_right_top, libvlc_video_orient_right_bottom:
      // Transposed and quarter-turn orientations swap the axes.
      return CGSize(width: displayHeight, height: displayWidth)
    default:
      return CGSize(width: displayWidth, height: displayHeight)
    }
  }

  /// Whether a video track is currently selected with known decoded
  /// dimensions.
  ///
  /// Implemented as ``videoSize`` `!= nil` — a selected-track probe,
  /// not a video-output query. `false` for audio-only media and idle
  /// players. Observers are re-signaled when the output count changes,
  /// on track changes, and when media is replaced.
  ///
  /// Not backed by `libvlc_media_player_has_vout`: libVLC 4 pre-creates
  /// a window-holding vout when the player is created, so the native
  /// vout count reads `1` even on an idle player with no media. The
  /// size probe only succeeds while a video track is actually selected
  /// and decoding.
  public var hasVideoOutput: Bool {
    access(keyPath: \.hasVideoOutput)
    return videoSize != nil
  }
}
