@testable import SwiftVLC
import Testing

/// `Track.codecString` decodes the little-endian-packed FourCC in
/// ``Track/codec`` so callers do not reverse the bytes (the `"462h"` bug).
extension Logic {
  struct TrackCodecStringTests {
    /// Packs a FourCC the way libVLC stores it: first character in the low
    /// byte. Bytes beyond the string stay zero (trailing NUL padding).
    private func packed(_ string: String) -> Int {
      var value: UInt32 = 0
      for (index, byte) in string.utf8.enumerated() where index < 4 {
        value |= UInt32(byte) << (8 * index)
      }
      return Int(value)
    }

    private func track(codec: Int) -> Track {
      Track(
        id: "t",
        type: .video,
        name: "Track",
        codec: codec,
        language: nil,
        trackDescription: nil,
        isSelected: false,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: nil,
        height: nil,
        frameRate: nil,
        encoding: nil
      )
    }

    @Test(arguments: ["h264", "mp4a", "hvc1", "avc1"])
    func `decodes a four-character codec`(fourcc: String) {
      #expect(track(codec: packed(fourcc)).codecString == fourcc)
    }

    @Test
    func `a trailing NUL ends the string`() {
      // 'm','p','3', 0x00
      #expect(track(codec: packed("mp3")).codecString == "mp3")
    }

    @Test
    func `a trailing space is kept`() {
      #expect(track(codec: packed("mp2 ")).codecString == "mp2 ")
    }

    @Test
    func `a non-printable non-trailing byte yields nil`() {
      // 'h', 0xFF, '6', '4': the 0xFF is not a printable FourCC byte.
      let codec = Int(UInt32(0x68) | (UInt32(0xFF) << 8) | (UInt32(0x36) << 16) | (UInt32(0x34) << 24))
      #expect(track(codec: codec).codecString == nil)
    }

    @Test
    func `an embedded NUL with later bytes yields nil`() {
      // 'h', 0x00, '6', '4': the NUL is not trailing padding.
      let codec = Int(UInt32(0x68) | (UInt32(0x36) << 16) | (UInt32(0x34) << 24))
      #expect(track(codec: codec).codecString == nil)
    }

    @Test
    func `a zero codec yields nil`() {
      #expect(track(codec: 0).codecString == nil)
    }
  }
}
