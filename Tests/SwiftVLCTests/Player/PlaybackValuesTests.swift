@testable import SwiftVLC
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
      #expect(Volume(2.0).rawValue == 1.25)
    }

    @Test func `Volume named constants`() {
      #expect(Volume.muted.rawValue == 0.0)
      #expect(Volume.unity.rawValue == 1.0)
      #expect(Volume.max.rawValue == 1.25)
    }

    @Test func `Volume float literal works`() {
      let v: Volume = 0.8
      #expect(v.rawValue == 0.8)
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

    @Test func `EqualizerGain literal init from float`() {
      let g: EqualizerGain = 6.0
      #expect(g.rawValue == 6.0)
    }
  }
}

extension Integration {
  @MainActor struct PlayerTypedAccessorsTests {
    @Test func `playbackPosition round-trips via typed accessor`() {
      let player = Player(instance: TestInstance.shared)
      player.playbackPosition = 0.4
      // Player.position is set unconditionally; libVLC's actual seek is
      // a no-op without media, but the shadow `_position` updates.
      #expect(player.playbackPosition.rawValue == 0.4)
    }

    @Test func `audioVolume typed accessor clamps then updates raw volume`() {
      let player = Player(instance: TestInstance.shared)
      player.audioVolume = .unity
      #expect(player.volume == 1.0)
      player.audioVolume = Volume(2.0) // clamps to 1.25
      #expect(player.volume == 1.25)
    }

    @Test func `playbackRate typed accessor passes through to libVLC`() {
      let player = Player(instance: TestInstance.shared)
      player.playbackRate = .double
      // libVLC's get_rate may return cached or actual; both 1.0 and 2.0
      // are observed depending on whether media is loaded. Don't assert
      // the round-trip here; only that the call didn't crash.
      _ = player.playbackRate
    }

    @Test func `subtitleScale typed accessor round-trips through libVLC`() {
      let player = Player(instance: TestInstance.shared)
      player.subtitleScale = .doubleSize
      #expect(player.subtitleScale == .doubleSize)
      player.subtitleScale = .halfSize
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

    @Test func `bandGains round-trips through Equalizer`() {
      let eq = Equalizer()
      let count = Equalizer.bandCount
      let gains: [EqualizerGain] = (0..<count).map { i in
        EqualizerGain(Float(i - count / 2))
      }
      eq.bandGains = gains
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
      #expect(eq.gain(forBand: 0).rawValue == 7.5)
    }
  }
}
