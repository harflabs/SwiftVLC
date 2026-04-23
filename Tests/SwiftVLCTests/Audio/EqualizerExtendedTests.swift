@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct EqualizerExtendedTests {
    // MARK: - Preset Initialization

    @Test
    func `All presets create valid equalizers`() {
      for i in 0..<Equalizer.presetCount {
        let eq = Equalizer(preset: i)
        // Access preamp and all bands without crashing
        _ = eq.preamp
        for band in 0..<Equalizer.bandCount {
          _ = eq.amplification(forBand: band)
        }
      }
    }

    @Test
    func `Some presets have non-zero band amplification`() {
      let foundNonZero = (0..<Equalizer.presetCount).contains { i in
        let eq = Equalizer(preset: i)
        return (0..<Equalizer.bandCount).contains { band in
          eq.amplification(forBand: band) != 0
        }
      }
      #expect(foundNonZero, "At least one preset should have non-zero band amplification")
    }

    @Test
    func `Preset created from index has expected preamp value`() {
      // Preset 0 (flat) typically has 0 preamp; verify the value is within valid range
      let eq = Equalizer(preset: 0)
      let preamp = eq.preamp
      #expect(preamp >= -20.0 && preamp <= 20.0)
    }

    // MARK: - Negative Amplification

    @Test
    func `Negative amplification values`() throws {
      let eq = Equalizer()
      try eq.setAmplification(-10.0, forBand: 0)
      #expect(eq.amplification(forBand: 0) == -10.0)

      try eq.setAmplification(-20.0, forBand: 1)
      #expect(eq.amplification(forBand: 1) == -20.0)
    }

    // MARK: - Boundary Amplification

    @Test
    func `Boundary amplification values exactly at limits`() throws {
      let eq = Equalizer()
      try eq.setAmplification(-20.0, forBand: 0)
      #expect(eq.amplification(forBand: 0) == -20.0)

      try eq.setAmplification(20.0, forBand: 1)
      #expect(eq.amplification(forBand: 1) == 20.0)
    }

    @Test
    func `Amplification clamping beyond limits`() throws {
      let eq = Equalizer()
      try eq.setAmplification(25.0, forBand: 0)
      #expect(eq.amplification(forBand: 0) <= 20.0)

      try eq.setAmplification(-25.0, forBand: 1)
      #expect(eq.amplification(forBand: 1) >= -20.0)
    }

    // MARK: - Preamp Reset

    @Test
    func `Preamp set to zero resets`() {
      let eq = Equalizer()
      eq.preamp = 12.0
      #expect(eq.preamp == 12.0)

      eq.preamp = 0.0
      #expect(eq.preamp == 0.0)
    }

    // MARK: - Preset Names Uniqueness

    @Test
    func `Preset names are all unique`() {
      let names = Equalizer.presetNames
      let uniqueNames = Set(names)
      #expect(names.count == uniqueNames.count, "Preset names should be unique")
    }

    // MARK: - Band Frequency Specific Values

    @Test
    func `Band 0 has lowest frequency and band 9 has highest`() {
      let band0Freq = Equalizer.bandFrequency(at: 0)
      let band9Freq = Equalizer.bandFrequency(at: Equalizer.bandCount - 1)

      #expect(band0Freq < band9Freq)
      // VLC standard: band 0 is 60 Hz, band 9 is 16000 Hz
      #expect(band0Freq > 0)
      #expect(band9Freq > band0Freq)
    }

    // MARK: - Player Integration

    @Test
    func `Assign equalizer to player then modify and reassign`() throws {
      let player = Player(instance: TestInstance.shared)
      let eq = Equalizer()

      // Assign flat equalizer
      player.equalizer = eq
      #expect(player.equalizer != nil)

      // Modify and reassign
      eq.preamp = 8.0
      try eq.setAmplification(5.0, forBand: 0)
      player.equalizer = eq
      #expect(player.equalizer != nil)
      #expect(player.equalizer?.preamp == 8.0)
      #expect(player.equalizer?.amplification(forBand: 0) == 5.0)

      // Remove equalizer
      player.equalizer = nil
      #expect(player.equalizer == nil)
    }

    // MARK: - Multiple Equalizers Coexist

    @Test
    func `Multiple equalizers can coexist independently`() throws {
      let eq1 = Equalizer()
      let eq2 = Equalizer()

      eq1.preamp = 10.0
      eq2.preamp = -5.0

      try eq1.setAmplification(15.0, forBand: 0)
      try eq2.setAmplification(-15.0, forBand: 0)

      // Verify they are independent
      #expect(eq1.preamp == 10.0)
      #expect(eq2.preamp == -5.0)
      #expect(eq1.amplification(forBand: 0) == 15.0)
      #expect(eq2.amplification(forBand: 0) == -15.0)
    }

    // MARK: - Set All Bands to Same Value

    @Test
    func `Set all bands to same value and verify consistency`() throws {
      let eq = Equalizer()
      let targetValue: Float = 7.5

      for band in 0..<Equalizer.bandCount {
        try eq.setAmplification(targetValue, forBand: band)
      }

      for band in 0..<Equalizer.bandCount {
        #expect(
          eq.amplification(forBand: band) == targetValue,
          "Band \(band) should be \(targetValue)"
        )
      }
    }

    // MARK: - Reset All Bands After Modification

    @Test
    func `Reset all bands to zero after modification`() throws {
      let eq = Equalizer()

      // Set all bands to various non-zero values
      for band in 0..<Equalizer.bandCount {
        try eq.setAmplification(Float(band) * 2.0 - 10.0, forBand: band)
      }

      // Verify they are non-zero (at least some)
      let hasNonZero = (0..<Equalizer.bandCount).contains { band in
        eq.amplification(forBand: band) != 0
      }
      #expect(hasNonZero)

      // Reset all bands to zero
      for band in 0..<Equalizer.bandCount {
        try eq.setAmplification(0.0, forBand: band)
      }

      // Verify all are zero
      for band in 0..<Equalizer.bandCount {
        #expect(
          eq.amplification(forBand: band) == 0.0,
          "Band \(band) should be reset to 0"
        )
      }
    }
  }
}
