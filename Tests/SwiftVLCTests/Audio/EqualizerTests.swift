@testable import SwiftVLC
import Testing

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct EqualizerTests {
  @Test
  func `Flat init has preamp zero and all bands zero`() {
    let eq = Equalizer()
    #expect(eq.preamp == 0)
    for i in 0..<Equalizer.bandCount {
      #expect(eq.amplification(forBand: i) == 0)
    }
  }

  @Test
  func `Preset init`() {
    let eq = Equalizer(preset: 0)
    // First preset may have non-zero values
    _ = eq.preamp
  }

  @Test
  func `Preamp get and set`() {
    let eq = Equalizer()
    eq.preamp = 10.0
    #expect(eq.preamp == 10.0)
  }

  @Test
  func `Preamp clamping`() {
    let eq = Equalizer()
    eq.preamp = 25.0 // Over 20.0 max
    #expect(eq.preamp <= 20.0)
    eq.preamp = -25.0 // Under -20.0 min
    #expect(eq.preamp >= -20.0)
  }

  @Test
  func `Band count is positive`() {
    #expect(Equalizer.bandCount > 0)
    #expect(Equalizer.bandCount == 10) // VLC has 10 bands
  }

  @Test
  func `Band frequency is positive`() {
    for i in 0..<Equalizer.bandCount {
      #expect(Equalizer.bandFrequency(at: i) > 0)
    }
  }

  @Test
  func `Amplification get and set`() throws {
    let eq = Equalizer()
    try eq.setAmplification(5.0, forBand: 0)
    #expect(eq.amplification(forBand: 0) == 5.0)
  }

  @Test
  func `Invalid band throws`() {
    let eq = Equalizer()
    #expect(throws: VLCError.self) {
      try eq.setAmplification(5.0, forBand: 999)
    }
  }

  @Test
  func `Negative band index throws instead of trapping`() {
    let eq = Equalizer()
    #expect(throws: VLCError.self) {
      try eq.setAmplification(5.0, forBand: -1)
    }
  }

  @Test
  func `Preset count is positive`() {
    #expect(Equalizer.presetCount > 0)
  }

  @Test
  func `Preset names are non-empty`() {
    let names = Equalizer.presetNames
    #expect(!names.isEmpty)
    #expect(names.count == Equalizer.presetCount)
  }

  @Test
  func `Preset name at valid index`() throws {
    let name = try #require(Equalizer.presetName(at: 0))
    #expect(!name.isEmpty)
  }

  @Test
  func `Preset name at invalid index`() {
    let name = Equalizer.presetName(at: 9999)
    #expect(name == nil)
  }

  @Test
  func `Preset name at negative index returns nil`() {
    #expect(Equalizer.presetName(at: -1) == nil)
  }

  @Test
  func `All bands accessible`() throws {
    let eq = Equalizer()
    for i in 0..<Equalizer.bandCount {
      try eq.setAmplification(Float(i), forBand: i)
      #expect(eq.amplification(forBand: i) == Float(i))
    }
  }

  @Test
  func `Band frequencies increase`() {
    var prev: Float = 0
    for i in 0..<Equalizer.bandCount {
      let freq = Equalizer.bandFrequency(at: i)
      #expect(freq > prev)
      prev = freq
    }
  }
}
