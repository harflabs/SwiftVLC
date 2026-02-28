@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("AudioChannelMode", .tags(.logic))
struct AudioChannelModeTests {
  @Test(
    "StereoMode descriptions",
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
  func stereoModeDescriptions(mode: StereoMode, expected: String) {
    #expect(mode.description == expected)
  }

  @Test(
    "StereoMode cValue round-trip",
    arguments: [
      StereoMode.stereo, .reverseStereo, .left, .right, .dolbySurround, .mono,
    ]
  )
  func stereoModeCValueRoundTrip(mode: StereoMode) {
    let reconstructed = StereoMode(from: mode.cValue)
    #expect(reconstructed == mode)
  }

  @Test("StereoMode unknown defaults to .unset")
  func stereoModeUnknownDefaultsToUnset() {
    let mode = StereoMode(from: libvlc_audio_output_stereomode_t(rawValue: 999))
    #expect(mode == .unset)
  }

  @Test(
    "MixMode descriptions",
    arguments: [
      (MixMode.unset, "unset"),
      (.stereo, "stereo"),
      (.binaural, "binaural"),
      (.fourPointZero, "4.0"),
      (.fivePointOne, "5.1"),
      (.sevenPointOne, "7.1"),
    ] as [(MixMode, String)]
  )
  func mixModeDescriptions(mode: MixMode, expected: String) {
    #expect(mode.description == expected)
  }

  @Test(
    "MixMode cValue round-trip",
    arguments: [
      MixMode.stereo, .binaural, .fourPointZero, .fivePointOne, .sevenPointOne,
    ]
  )
  func mixModeCValueRoundTrip(mode: MixMode) {
    let reconstructed = MixMode(from: mode.cValue)
    #expect(reconstructed == mode)
  }

  @Test("MixMode unknown defaults to .unset")
  func mixModeUnknownDefaultsToUnset() {
    let mode = MixMode(from: libvlc_audio_output_mixmode_t(rawValue: 999))
    #expect(mode == .unset)
  }

  @Test("StereoMode Hashable")
  func stereoModeHashable() {
    let set: Set<StereoMode> = [.stereo, .mono, .stereo]
    #expect(set.count == 2)
  }

  @Test("MixMode Hashable")
  func mixModeHashable() {
    let set: Set<MixMode> = [.stereo, .binaural, .stereo]
    #expect(set.count == 2)
  }
}
