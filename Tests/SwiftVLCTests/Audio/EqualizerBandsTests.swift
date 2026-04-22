@testable import SwiftVLC
import Testing

/// Covers `Equalizer.bands` getter/setter and `setAmplification` error
/// paths. These exist in the existing `EqualizerTests` only at the
/// preamp level; this file drives the per-band machinery directly.
@Suite(.tags(.integration, .mainActor))
@MainActor
struct EqualizerBandsTests {
  // MARK: - Read

  @Test
  func `bands getter returns bandCount entries of flat 0 dB`() {
    let eq = Equalizer()
    let bands = eq.bands
    #expect(bands.count == Equalizer.bandCount)
    #expect(bands.allSatisfy { $0 == 0 })
  }

  @Test
  func `amplification(forBand:) reads the flat 0 dB default`() {
    let eq = Equalizer()
    for index in 0..<Equalizer.bandCount {
      #expect(eq.amplification(forBand: index) == 0)
    }
  }

  // MARK: - Write

  /// Assigning a new bands array must round-trip through libVLC and
  /// reflect on the next read.
  @Test
  func `bands setter applies each band through to libVLC`() {
    let eq = Equalizer()
    let target = (0..<Equalizer.bandCount).map { Float($0) - 5 }

    eq.bands = target

    let readBack = eq.bands
    for (index, value) in target.enumerated() {
      #expect(abs(readBack[index] - value) < 0.01, "Band \(index) did not round-trip: \(readBack[index]) vs \(value)")
    }
  }

  /// Assigning an equal array is a no-op that skips the write path —
  /// `onChange` must NOT fire and libVLC isn't touched. Observable with
  /// a change counter.
  @Test
  func `bands setter skips re-apply when values are unchanged`() {
    let eq = Equalizer()
    var changeCount = 0
    eq.onChange = { changeCount += 1 }

    let same = eq.bands
    eq.bands = same

    #expect(changeCount == 0, "Equal assignment should not trigger onChange")
  }

  @Test
  func `bands setter fires onChange when values differ`() {
    let eq = Equalizer()
    var changeCount = 0
    eq.onChange = { changeCount += 1 }

    var modified = eq.bands
    modified[0] = 3.0
    eq.bands = modified

    #expect(changeCount == 1, "Delta assignment should fire onChange exactly once")
  }

  // MARK: - setAmplification

  @Test
  func `setAmplification on a valid band succeeds and round-trips`() throws {
    let eq = Equalizer()
    try eq.setAmplification(5.5, forBand: 0)
    #expect(abs(eq.amplification(forBand: 0) - 5.5) < 0.01)
  }

  @Test
  func `setAmplification on a negative band throws`() {
    let eq = Equalizer()
    #expect(throws: VLCError.self) {
      try eq.setAmplification(3.0, forBand: -1)
    }
  }

  @Test
  func `setAmplification beyond bandCount throws`() {
    let eq = Equalizer()
    #expect(throws: VLCError.self) {
      try eq.setAmplification(3.0, forBand: Equalizer.bandCount)
    }
  }

  @Test
  func `setAmplification fires onChange on success`() throws {
    let eq = Equalizer()
    var changeCount = 0
    eq.onChange = { changeCount += 1 }

    try eq.setAmplification(1.5, forBand: 0)

    #expect(changeCount == 1)
  }

  // MARK: - Presets

  /// Every preset must construct a valid equalizer. If libVLC drops a
  /// preset in a future release, this catches it.
  @Test
  func `Every preset index constructs a valid Equalizer`() {
    for index in 0..<Equalizer.presetCount {
      let eq = Equalizer(preset: index)
      #expect(eq.bands.count == Equalizer.bandCount)
    }
  }

  /// `presetName(at:)` must return a non-nil string for every valid
  /// index and nil for out-of-range indices.
  @Test
  func `presetName handles valid and invalid indices`() {
    for index in 0..<Equalizer.presetCount {
      let name = Equalizer.presetName(at: index)
      #expect(name != nil && !name!.isEmpty)
    }
    #expect(Equalizer.presetName(at: -1) == nil)
    #expect(Equalizer.presetName(at: Equalizer.presetCount) == nil)
  }

  @Test
  func `presetNames returns a non-empty set of distinct strings`() {
    let names = Equalizer.presetNames
    #expect(names.count == Equalizer.presetCount)
    #expect(Set(names).count == names.count, "Presets must have distinct names")
  }

  // MARK: - bandFrequency static accessor

  @Test
  func `bandFrequency returns distinct increasing frequencies`() {
    let frequencies = (0..<Equalizer.bandCount).map { Equalizer.bandFrequency(at: $0) }
    #expect(frequencies.allSatisfy { $0 > 0 })
    for i in 1..<frequencies.count {
      #expect(frequencies[i] > frequencies[i - 1], "Band frequencies must be monotonically increasing")
    }
  }
}
