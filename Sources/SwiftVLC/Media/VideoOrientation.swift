import CLibVLC

/// The display orientation of encoded video pixels.
/// Raw values use EXIF / ImageIO's orientation convention.
public enum VideoOrientation: UInt32, Sendable, Hashable {
  case up = 1
  case upMirrored = 2
  case down = 3
  case downMirrored = 4
  case leftMirrored = 5
  case right = 6
  case rightMirrored = 7
  case left = 8

  init(from value: libvlc_video_orient_t) {
    switch value {
    case libvlc_video_orient_top_left: self = .up
    case libvlc_video_orient_top_right: self = .upMirrored
    case libvlc_video_orient_bottom_left: self = .downMirrored
    case libvlc_video_orient_bottom_right: self = .down
    case libvlc_video_orient_left_top: self = .leftMirrored
    case libvlc_video_orient_left_bottom: self = .left
    case libvlc_video_orient_right_top: self = .right
    case libvlc_video_orient_right_bottom: self = .rightMirrored
    default: self = .up
    }
  }
}
