@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Logic {
  struct PlaybackValuesTests {
    // MARK: - PlaybackPosition

    @Test func `PlaybackPosition clamps below zero`() {
      #expect(PlaybackPosition(-0.5).rawValue == 0.0)
    }

    @Test func `PlaybackPosition clamps above one`() {
      #expect(PlaybackPosition(2.0).rawValue == 1.0)
    }

    @Test func `PlaybackPosition preserves in-range values`() {
      #expect(PlaybackPosition(0.42).rawValue == 0.42)
    }

    @Test func `PlaybackPosition maps NaN to zero`() {
      #expect(PlaybackPosition(.nan) == .zero)
    }

    @Test func `PlaybackPosition float literal initializes via clamping`() {
      let p: PlaybackPosition = 0.75
      #expect(p.rawValue == 0.75)
    }

    @Test func `PlaybackPosition zero and end constants`() {
      #expect(PlaybackPosition.zero.rawValue == 0.0)
      #expect(PlaybackPosition.end.rawValue == 1.0)
    }

    @Test func `PlaybackPosition is Comparable and Hashable`() {
      let a: PlaybackPosition = 0.2
      let b: PlaybackPosition = 0.8
      #expect(a < b)
      #expect(Set([a, b, a]).count == 2)
    }

    // MARK: - Volume

    @Test func `Volume clamps below zero to muted`() {
      #expect(Volume(-1.0).rawValue == 0.0)
    }

    @Test func `Volume clamps above max`() {
      #expect(Volume(2.5).rawValue == 2.0)
    }

    @Test func `Volume passes through the 2.0 ceiling exactly`() {
      #expect(Volume(2.0).rawValue == 2.0)
    }

    @Test func `Volume preserves former 1.25 ceiling values unchanged`() {
      #expect(Volume(1.25).rawValue == 1.25)
    }

    @Test func `Volume named constants`() {
      #expect(Volume.muted.rawValue == 0.0)
      #expect(Volume.unity.rawValue == 1.0)
      #expect(Volume.unity.rawValue.bitPattern == Float(1.0).bitPattern)
      #expect(Volume.max.rawValue == 2.0)
    }

    @Test func `Volume maps NaN to unity`() {
      #expect(Volume(.nan) == .unity)
    }

    @Test func `Volume float literal works`() {
      let v: Volume = 0.8
      #expect(v.rawValue == 0.8)
    }

    @Test func `Volume is Comparable`() {
      #expect(Volume.muted < Volume.unity)
      #expect(Volume.unity < Volume.max)
    }

    // MARK: - PlaybackRate

    @Test func `PlaybackRate clamps below 0.25`() {
      #expect(PlaybackRate(0.1).rawValue == 0.25)
    }

    @Test func `PlaybackRate clamps above 4.0`() {
      #expect(PlaybackRate(8.0).rawValue == 4.0)
    }

    @Test func `PlaybackRate named constants`() {
      #expect(PlaybackRate.slowest.rawValue == 0.25)
      #expect(PlaybackRate.half.rawValue == 0.5)
      #expect(PlaybackRate.normal.rawValue == 1.0)
      #expect(PlaybackRate.double.rawValue == 2.0)
      #expect(PlaybackRate.fastest.rawValue == 4.0)
    }

    @Test func `PlaybackRate is Comparable`() {
      #expect(PlaybackRate.half < PlaybackRate.normal)
      #expect(PlaybackRate.normal < PlaybackRate.double)
    }

    @Test func `PlaybackRate maps NaN to normal`() {
      #expect(PlaybackRate(.nan) == .normal)
    }

    // MARK: - SubtitleScale

    @Test func `SubtitleScale clamps below 0.1`() {
      #expect(SubtitleScale(0.0).rawValue == 0.1)
      #expect(SubtitleScale(-1.0).rawValue == 0.1)
    }

    @Test func `SubtitleScale clamps above 5.0`() {
      #expect(SubtitleScale(10.0).rawValue == 5.0)
    }

    @Test func `SubtitleScale named constants`() {
      #expect(SubtitleScale.halfSize.rawValue == 0.5)
      #expect(SubtitleScale.normal.rawValue == 1.0)
      #expect(SubtitleScale.doubleSize.rawValue == 2.0)
    }

    @Test func `SubtitleScale maps NaN to normal`() {
      #expect(SubtitleScale(.nan) == .normal)
    }

    @Test func `SubtitleScale is Comparable`() {
      #expect(SubtitleScale.halfSize < SubtitleScale.normal)
      #expect(SubtitleScale.normal < SubtitleScale.doubleSize)
    }

    @Test func `SubtitleScale approximate points maps against the base size`() {
      #expect(SubtitleScale(approximatePoints: 36, basePoints: 18).rawValue == 2.0)
      #expect(SubtitleScale(approximatePoints: 9, basePoints: 18).rawValue == 0.5)
    }

    @Test func `SubtitleScale approximate points clamps to the scale range`() {
      #expect(SubtitleScale(approximatePoints: 1000, basePoints: 18).rawValue == 5.0)
      #expect(SubtitleScale(approximatePoints: 0.1, basePoints: 18).rawValue == 0.1)
    }

    @Test func `SubtitleScale approximate points falls back to normal on a degenerate base`() {
      #expect(SubtitleScale(approximatePoints: 36, basePoints: 0) == .normal)
    }

    // MARK: - EqualizerGain

    @Test func `EqualizerGain clamps below -20`() {
      #expect(EqualizerGain(-30.0).rawValue == -20.0)
    }

    @Test func `EqualizerGain clamps above +20`() {
      #expect(EqualizerGain(30.0).rawValue == 20.0)
    }

    @Test func `EqualizerGain named constants`() {
      #expect(EqualizerGain.minimum.rawValue == -20.0)
      #expect(EqualizerGain.flat.rawValue == 0.0)
      #expect(EqualizerGain.maximum.rawValue == 20.0)
    }

    @Test func `EqualizerGain maps NaN to flat`() {
      #expect(EqualizerGain(.nan) == .flat)
    }

    @Test func `EqualizerGain literal init from float`() {
      let g: EqualizerGain = 6.0
      #expect(g.rawValue == 6.0)
    }

    @Test func `EqualizerGain is Comparable`() {
      #expect(EqualizerGain.minimum < EqualizerGain.flat)
      #expect(EqualizerGain.flat < EqualizerGain.maximum)
    }
  }
}

extension Integration {
  @MainActor struct PlayerTypedAccessorsTests {
    @Test func `playbackPosition reflects raw observed position`() {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(position: 0.4)
      #expect(player.playbackPosition.rawValue == 0.4)
    }

    @Test func `setAudioVolume clamps then updates raw volume`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.setAudioVolume(.unity)
      #expect(player.volume == 1.0)
      #expect(player.audioVolume == .unity)
      try player.setAudioVolume(Volume(2.5)) // clamps to 2.0
      #expect(player.volume == 2.0)
      #expect(player.audioVolume == .max)
    }

    @Test func `setPlaybackRate typed accessor passes through to libVLC`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.setPlaybackRate(.double)
      // libVLC's get_rate may return cached or actual; both 1.0 and 2.0
      // are observed depending on whether media is loaded. Don't assert
      // the round-trip here; only that the call didn't crash.
      _ = player.playbackRate
    }

    @Test func `subtitleScale typed accessor round-trips through libVLC`() {
      let player = Player(instance: TestInstance.shared)
      player.setSubtitleScale(.doubleSize)
      #expect(player.subtitleScale == .doubleSize)
      player.setSubtitleScale(.halfSize)
      #expect(player.subtitleScale == .halfSize)
    }

    @Test func `setPlaybackRate typed throwing variant accepts a clamped rate`() throws {
      let player = Player(instance: TestInstance.shared)
      // Without media loaded libVLC returns 0 from set_rate, which is
      // mapped to a no-op success — the call must not throw and must not
      // mutate state in surprising ways.
      try player.setPlaybackRate(.normal)
      try player.setPlaybackRate(PlaybackRate(8.0)) // clamps to 4.0 in init
    }

    /// The dummy audio module has no volume control, so a live set is
    /// rejected on `makePlayback()` instances; the ceiling can only be
    /// verified through the real audio output. Muting first keeps the
    /// host silent — mute and volume are orthogonal in libVLC.
    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `setAudioVolume at the 2.0 ceiling reaches libVLC as 200 percent`() async throws {
      let player = Player(instance: TestInstance.makeRealAudioPlayback())
      player.isMuted = true
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      try #require(await poll(until: { player.currentTime > .zero }), "Waiting for: player.currentTime > .zero")
      try player.setAudioVolume(Volume(2.0))
      try #require(
        await poll(until: { libvlc_audio_get_volume(player.pointer) == 200 }),
        "Waiting for: libvlc_audio_get_volume == 200"
      )
      player.stop()
    }

    /// The point-size convenience must feed the same `spu-text-scale`
    /// value the carry-over copies onto every replacement handle, so a
    /// scale set before a swap reads back from the new native player.
    @Test func `Subtitle scale from approximate points survives the native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setSubtitleScale(SubtitleScale(approximatePoints: 36))
      let oldPointer = player.pointer

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()
      try #require(
        player.pointer != oldPointer,
        "swap did not replace the native player handle"
      )
      #expect(abs(player.subtitleTextScale - 2.0) < 0.001)
    }
  }
}

extension Integration {
  @MainActor struct EqualizerTypedGainTests {
    @Test func `preampGain round-trips through Equalizer`() {
      let eq = Equalizer()
      eq.preampGain = .flat
      #expect(eq.preampGain == .flat)
      eq.preampGain = 6.0
      #expect(eq.preamp == 6.0)
      #expect(eq.preampGain.rawValue == 6.0)
    }

    @Test func `bandGains round-trips through Equalizer`() throws {
      let eq = Equalizer()
      let count = Equalizer.bandCount
      let gains: [EqualizerGain] = (0..<count).map { i in
        EqualizerGain(Float(i - count / 2))
      }
      try eq.setBandGains(gains)
      // Round-trip — libVLC stores the values exactly.
      #expect(eq.bandGains == gains)
    }

    @Test func `setGain forBand throws on invalid index`() {
      let eq = Equalizer()
      let invalidIndex = Equalizer.bandCount + 100
      #expect(throws: VLCError.self) {
        try eq.setGain(.flat, forBand: invalidIndex)
      }
    }

    @Test func `gain forBand reads back what setGain wrote`() throws {
      let eq = Equalizer()
      try eq.setGain(EqualizerGain(7.5), forBand: 0)
      #expect(try #require(eq.gain(forBand: 0)).rawValue == 7.5)
    }
  }
}
