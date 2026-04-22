@testable import SwiftVLC
import Foundation
import Testing

/// Covers the error paths on `Player`'s `throws(VLCError)` API.
///
/// Each test forces libVLC into a state where the underlying call is
/// guaranteed to fail, then asserts the typed-throw shape. Pairs with
/// `PlayerTests` which covers the success paths.
@Suite(.tags(.integration, .mainActor))
@MainActor
struct PlayerThrowsTests {
  // MARK: - setRenderer

  /// `setRenderer` is defended at the Swift layer against being called
  /// while the player is active — the operation would corrupt libVLC's
  /// internal state. The guard throws before libVLC is even reached.
  @Test
  func `setRenderer while buffering throws invalidState-shaped error`() throws {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .buffering)
    #expect(throws: VLCError.self) {
      try player.setRenderer(nil)
    }
  }

  @Test
  func `setRenderer while playing throws`() throws {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .playing)
    #expect(throws: VLCError.self) {
      try player.setRenderer(nil)
    }
  }

  @Test
  func `setRenderer while paused throws`() throws {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .paused)
    #expect(throws: VLCError.self) {
      try player.setRenderer(nil)
    }
  }

  @Test
  func `setRenderer while idle succeeds`() throws {
    let player = Player(instance: TestInstance.shared)
    // Default state is .idle — no setup needed.
    try player.setRenderer(nil)
  }

  @Test
  func `setRenderer while stopped succeeds`() throws {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .stopped)
    try player.setRenderer(nil)
  }

  // MARK: - setDeinterlace

  /// Deinterlacing options are applied via a libVLC variable set that
  /// currently accepts any string; the failure path is the C-call
  /// returning non-zero, which happens for unrecognized filter names
  /// on some builds. The happy-path `state: -1` (auto) always succeeds.
  @Test
  func `setDeinterlace auto succeeds`() throws {
    let player = Player(instance: TestInstance.shared)
    try player.setDeinterlace(state: -1)
  }

  @Test
  func `setDeinterlace disable succeeds`() throws {
    let player = Player(instance: TestInstance.shared)
    try player.setDeinterlace(state: 0)
  }

  @Test
  func `setDeinterlace with named mode succeeds`() throws {
    let player = Player(instance: TestInstance.shared)
    try player.setDeinterlace(state: 1, mode: "blend")
  }

  // MARK: - setRate

  @Test
  func `setRate positive value succeeds`() throws {
    let player = Player(instance: TestInstance.shared)
    try player.setRate(1.0)
    try player.setRate(0.5)
    try player.setRate(2.0)
  }

  /// Documents an observed libVLC quirk: `set_rate(0)` returns 0
  /// (success) even though 0 is not a meaningful playback rate — it's
  /// equivalent to a pause. This test pins the behavior so a future
  /// libVLC that starts rejecting 0 is caught as a surprise rather
  /// than masked.
  @Test
  func `setRate zero is accepted by libVLC (documents the quirk)`() throws {
    let player = Player(instance: TestInstance.shared)
    try player.setRate(0)
  }

  // MARK: - setAudioOutput

  /// Unknown audio-output modules are rejected by libVLC.
  @Test
  func `setAudioOutput with unknown module throws`() throws {
    let player = Player(instance: TestInstance.shared)
    #expect(throws: VLCError.self) {
      try player.setAudioOutput("definitely-not-a-real-aout-\(UUID().uuidString)")
    }
  }

  // MARK: - A-B loop error paths

  /// A-B loop requires the player to have a loaded media with a known
  /// duration. Calling it on an idle player should return non-zero
  /// from libVLC.
  @Test
  func `setABLoop by time without media throws`() throws {
    let player = Player(instance: TestInstance.shared)
    #expect(throws: VLCError.self) {
      try player.setABLoop(a: .seconds(1), b: .seconds(2))
    }
  }

  @Test
  func `setABLoop by position without media throws`() throws {
    let player = Player(instance: TestInstance.shared)
    #expect(throws: VLCError.self) {
      try player.setABLoop(aPosition: 0.1, bPosition: 0.2)
    }
  }

  // MARK: - addExternalTrack

  /// External tracks require a non-empty URI. An empty file URL is
  /// rejected by libVLC.
  @Test
  func `addExternalTrack with unsupported scheme throws`() throws {
    let player = Player(instance: TestInstance.shared)
    let badURL = try #require(URL(string: "completely-unknown-scheme://nowhere"))
    #expect(throws: VLCError.self) {
      try player.addExternalTrack(from: badURL, type: .subtitle)
    }
  }
}
