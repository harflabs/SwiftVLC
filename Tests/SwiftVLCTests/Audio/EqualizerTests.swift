@testable import SwiftVLC
import Testing

@Suite("Equalizer", .tags(.integration, .mainActor))
@MainActor
struct EqualizerTests {
  @Test("Flat init has preamp zero and all bands zero")
  func flatInit() {
    let eq = Equalizer()
    #expect(eq.preamp == 0)
    for i in 0..<Equalizer.bandCount {
      #expect(eq.amplification(forBand: i) == 0)
    }
  }

  @Test("Preset init")
  func presetInit() {
    let eq = Equalizer(preset: 0)
    // First preset may have non-zero values
    _ = eq.preamp
  }

  @Test("Preamp get and set")
  func preampGetSet() {
    let eq = Equalizer()
    eq.preamp = 10.0
    #expect(eq.preamp == 10.0)
  }

  @Test("Preamp clamping")
  func preampClamping() {
    let eq = Equalizer()
    eq.preamp = 25.0 // Over 20.0 max
    #expect(eq.preamp <= 20.0)
    eq.preamp = -25.0 // Under -20.0 min
    #expect(eq.preamp >= -20.0)
  }

  @Test("Band count is positive")
  func bandCountPositive() {
    #expect(Equalizer.bandCount > 0)
    #expect(Equalizer.bandCount == 10) // VLC has 10 bands
  }

  @Test("Band frequency is positive")
  func bandFrequencyPositive() {
    for i in 0..<Equalizer.bandCount {
      #expect(Equalizer.bandFrequency(at: i) > 0)
    }
  }

  @Test("Amplification get and set")
  func amplificationGetSet() throws {
    let eq = Equalizer()
    try eq.setAmplification(5.0, forBand: 0)
    #expect(eq.amplification(forBand: 0) == 5.0)
  }

  @Test("Invalid band throws")
  func invalidBandThrows() {
    let eq = Equalizer()
    #expect(throws: VLCError.self) {
      try eq.setAmplification(5.0, forBand: 999)
    }
  }

  @Test("Preset count is positive")
  func presetCountPositive() {
    #expect(Equalizer.presetCount > 0)
  }

  @Test("Preset names are non-empty")
  func presetNamesNonEmpty() {
    let names = Equalizer.presetNames
    #expect(!names.isEmpty)
    #expect(names.count == Equalizer.presetCount)
  }

  @Test("Preset name at valid index")
  func presetNameValidIndex() throws {
    let name = try #require(Equalizer.presetName(at: 0))
    #expect(!name.isEmpty)
  }

  @Test("Preset name at invalid index")
  func presetNameInvalidIndex() {
    let name = Equalizer.presetName(at: 9999)
    #expect(name == nil)
  }

  @Test("All bands accessible")
  func allBandsAccessible() throws {
    let eq = Equalizer()
    for i in 0..<Equalizer.bandCount {
      try eq.setAmplification(Float(i), forBand: i)
      #expect(eq.amplification(forBand: i) == Float(i))
    }
  }

  @Test("Band frequencies increase")
  func bandFrequenciesIncrease() {
    var prev: Float = 0
    for i in 0..<Equalizer.bandCount {
      let freq = Equalizer.bandFrequency(at: i)
      #expect(freq > prev)
      prev = freq
    }
  }
}
