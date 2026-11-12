import CLibVLC
import Foundation
import Testing

@testable import SwiftVLC

struct VideoOrientationTests {
  @Test func parsedVideoReportsItsDisplayOrientation() async throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "orientation-90", withExtension: "mp4", subdirectory: "Fixtures"))
    let media = try Media(url: url)
    _ = try await media.parse(timeout: .seconds(10))
    #expect(media.tracks().first(where: { $0.type == .video })?.orientation == .left)
  }
  @Test func libVLCOrientationsUseImageIOConventions() {
    let orientations: [(libvlc_video_orient_t, VideoOrientation)] = [
      (libvlc_video_orient_top_left, .up),
      (libvlc_video_orient_top_right, .upMirrored),
      (libvlc_video_orient_bottom_left, .downMirrored),
      (libvlc_video_orient_bottom_right, .down),
      (libvlc_video_orient_left_top, .leftMirrored),
      (libvlc_video_orient_left_bottom, .left),
      (libvlc_video_orient_right_top, .right),
      (libvlc_video_orient_right_bottom, .rightMirrored),
    ]
    for (native, expected) in orientations {
      #expect(VideoOrientation(from: native) == expected)
    }
  }
}
