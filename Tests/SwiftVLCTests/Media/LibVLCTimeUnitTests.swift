@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// A tripwire for the engine pin's time unit.
///
/// `libvlc_time_t` is **milliseconds** at the pinned revision. Later libVLC
/// revisions redefine it as **microseconds**, and that change is silent: the
/// C types are identical, nothing stops compiling, and every duration,
/// position and seek target in the package quietly becomes wrong by a factor
/// of a thousand. `scripts/build-libvlc.sh` calls this out as the reason the
/// pin is not tracked automatically, and issue #79 makes auditing it an
/// acceptance criterion for ever moving the pin.
///
/// An audit is a document that goes stale. This is the same check, executable:
/// parse fixtures whose real durations are known and assert the engine reports
/// them in milliseconds. If the pin moves past the unit change, these fail
/// immediately and say why, rather than shipping a player whose scrubber is
/// off by 1000×.
///
/// Parsing, not playback — so this runs on a headless CI host, which cannot
/// reach `.playing` (see `TestCondition.canPlayMedia`).
@Suite(.tags(.integration), .serialized)
struct LibVLCTimeUnitTests {
  /// Fixtures whose durations are fixed by how they were generated, with the
  /// tolerance container overhead needs. A microsecond engine would report
  /// these ~1000× larger, so no plausible tolerance hides the change.
  private static let fixtures: [(name: String, url: URL, expectedMilliseconds: Int64)] = [
    ("twosec.mp4", TestMedia.twosecURL, 2000),
    ("test.mp4", TestMedia.testMP4URL, 1000),
    ("sparse.mp4", TestMedia.sparseURL, 20000)
  ]

  @Test(arguments: fixtures)
  func `Parsed durations are reported in milliseconds`(fixture: (name: String, url: URL, expectedMilliseconds: Int64)) async throws {
    let media = try Media(url: fixture.url)
    _ = try? await media.parse()

    let reported = libvlc_media_get_duration(media.pointer)
    try #require(reported > 0, "\(fixture.name) did not parse; the assertion below would be vacuous")

    // Generous on purpose: container overhead moves the real value by tens of
    // milliseconds, while the unit change moves it by three orders of
    // magnitude. This distinguishes those without being brittle.
    let lower = fixture.expectedMilliseconds / 2
    let upper = fixture.expectedMilliseconds * 2
    #expect(
      reported > lower && reported < upper,
      """
      \(fixture.name) reported \(reported) for a \(fixture.expectedMilliseconds)ms asset.
      If this is ~1000x too large, the engine pin has moved past libVLC's \
      libvlc_time_t change from milliseconds to microseconds, and every \
      duration, position and seek conversion in the package needs auditing \
      before the pin lands. See issue #79 and scripts/build-libvlc.sh.
      """
    )
  }

  /// The same invariant at the player boundary, which is where the wrapper
  /// actually does the conversion: `Player+Events.swift` reads
  /// `libvlc_media_player_get_length` and builds a `Duration` from it as
  /// milliseconds. A unit change would make `duration` a thousand times too
  /// long without any type error.
  @Test
  func `Player duration conversion assumes milliseconds`() async throws {
    let player = await MainActor.run { Player(instance: TestInstance.makeAudioOnly()) }
    let media = try Media(url: TestMedia.twosecURL)
    _ = try? await media.parse()
    let milliseconds = libvlc_media_get_duration(media.pointer)
    try #require(milliseconds > 0, "the fixture did not parse")

    // The conversion the wrapper performs, isolated from playback so it is
    // reachable on a headless host.
    let converted = Duration.milliseconds(milliseconds)

    #expect(
      converted >= .milliseconds(1000) && converted <= .milliseconds(4000),
      "a 2s asset converted to \(converted); the engine's time unit is not milliseconds"
    )
    await player.shutdown()
  }
}
