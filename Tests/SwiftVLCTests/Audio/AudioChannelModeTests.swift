@testable import SwiftVLC
import CLibVLC
import Testing

extension Logic {
  struct AudioChannelModeTests {
    @Test(
      arguments: [
        (StereoMode.unset, "unset"),
        (.stereo, "stereo"),
        (.reverseStereo, "reverse stereo"),
        (.left, "left"),
        (.right, "right"),
        (.dolbySurround, "Dolby Surround"),
        (.mono, "mono")
      ] as [(StereoMode, String)]
    )
    func `StereoMode descriptions`(mode: StereoMode, expected: String) {
      #expect(mode.description == expected)
    }

    @Test(
      arguments: [
        StereoMode.stereo, .reverseStereo, .left, .right, .dolbySurround, .mono,
      ]
    )
    func `StereoMode cValue round-trip`(mode: StereoMode) {
      let reconstructed = StereoMode(from: mode.cValue)
      #expect(reconstructed == mode)
    }

    @Test
    func `StereoMode unknown defaults to .unset`() {
      let mode = StereoMode(from: libvlc_audio_output_stereomode_t(rawValue: 999))
      #expect(mode == .unset)
    }

    @Test(
      arguments: [
        (MixMode.unset, "unset"),
        (.stereo, "stereo"),
        (.binaural, "binaural"),
        (.fourPointZero, "4.0"),
        (.fivePointOne, "5.1"),
        (.sevenPointOne, "7.1"),
      ] as [(MixMode, String)]
    )
    func `MixMode descriptions`(mode: MixMode, expected: String) {
      #expect(mode.description == expected)
    }

    @Test(
      arguments: [
        MixMode.stereo, .binaural, .fourPointZero, .fivePointOne, .sevenPointOne,
      ]
    )
    func `MixMode cValue round-trip`(mode: MixMode) {
      let reconstructed = MixMode(from: mode.cValue)
      #expect(reconstructed == mode)
    }

    @Test
    func `MixMode unknown defaults to .unset`() {
      let mode = MixMode(from: libvlc_audio_output_mixmode_t(rawValue: 999))
      #expect(mode == .unset)
    }

    @Test
    func `StereoMode Hashable`() {
      let set: Set<StereoMode> = [.stereo, .mono, .stereo]
      #expect(set.count == 2)
    }

    @Test
    func `MixMode Hashable`() {
      let set: Set<MixMode> = [.stereo, .binaural, .stereo]
      #expect(set.count == 2)
    }
  }
}
