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
    var width: UInt32 = 0
    var height: UInt32 = 0
    guard
      libvlc_video_get_size(pointer, 0, &width, &height) == 0,
      width > 0, height > 0
    else { return nil }
    return CGSize(width: Int(width), height: Int(height))
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
