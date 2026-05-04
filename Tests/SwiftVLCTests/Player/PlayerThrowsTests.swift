@testable import SwiftVLC
import Foundation
import Testing

/// Covers the error paths on `Player`'s `throws(VLCError)` API.
///
/// Each test forces libVLC into a state where the underlying call is
/// guaranteed to fail, then asserts the typed-throw shape. Pairs with
/// `PlayerTests` which covers the success paths.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerThrowsTests {
    // MARK: - setRenderer

    /// `setRenderer` is defended at the Swift layer against being called
    /// after playback has started. libVLC only applies renderer selection
    /// before the native media player's first play, so SwiftVLC rejects
    /// unsupported retargeting before libVLC is reached.
    @Test
    func `setRenderer while buffering throws before reaching libVLC`() throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .buffering)
      #expect(throws: VLCError.invalidState("setRenderer requires idle, stopped, or error state; current state is buffering")) {
        try player.setRenderer(nil)
      }
    }

    @Test
    func `setRenderer while playing throws`() throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing)
      #expect(throws: VLCError.invalidState("setRenderer requires idle, stopped, or error state; current state is playing")) {
        try player.setRenderer(nil)
      }
    }

    @Test
    func `setRenderer while paused throws`() throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .paused)
      #expect(throws: VLCError.invalidState("setRenderer requires idle, stopped, or error state; current state is paused")) {
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

    @Test
    func `setRenderer while stopped after playback started throws`() throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .stopped)
      player.nativePlayerHasStartedPlayback = true

      #expect(throws: VLCError.invalidState("setRenderer must be called before the first play() on this Player")) {
        try player.setRenderer(nil)
      }
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

    @Test
    func `setDeinterlace rejects unrepresentable state instead of trapping`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try player.setDeinterlace(state: Int.max)
      }
    }

    @Test
    func `setDeinterlace rejects undefined state values`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.invalidInput("state must be -1 (auto), 0 (off), or 1 (on)")) {
        try player.setDeinterlace(state: 2)
      }
      #expect(throws: VLCError.invalidInput("state must be -1 (auto), 0 (off), or 1 (on)")) {
        try player.setDeinterlace(state: -2)
      }
    }

    #if os(macOS)
    @Test
    func `setDeinterlace rejects active macOS hardware decoded playback`() throws {
      let player = try Player(instance: VLCInstance(arguments: VLCInstance.defaultArguments))
      player._setStateForTesting(state: .playing)

      #expect(throws: VLCError.self) {
        try player.setDeinterlace(state: 1, mode: "yadif")
      }
    }

    @Test
    func `setDeinterlace allows active macOS software decoded playback`() throws {
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + [
          "--codec=avcodec"
        ]
      )
      let player = Player(instance: instance)
      player._setStateForTesting(state: .playing)

      try player.setDeinterlace(state: 1, mode: "blend")
    }
    #endif

    // MARK: - snapshot

    @Test
    func `takeSnapshot rejects invalid dimensions before calling libVLC`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.self) {
        try player.takeSnapshot(to: "/tmp/swiftvlc-invalid-snapshot.png", width: -1)
      }
    }

    // MARK: - teletext

    @Test
    func `setTeletextPage rejects values outside libVLC page domain`() throws {
      let player = Player(instance: TestInstance.shared)
      #expect(throws: VLCError.invalidInput("teletext page must be 0 or in 1...999")) {
        try player.setTeletextPage(-1)
      }
      #expect(throws: VLCError.invalidInput("teletext page must be 0 or in 1...999")) {
        try player.setTeletextPage(1000)
      }
    }

    @Test
    func `setTeletextPage accepts disable and valid pages`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.setTeletextPage(0)
      try player.setTeletextPage(100)
      try player.setTeletextPage(999)
    }

    @Test
    func `sendTeletextKey accepts typed keys`() {
      let player = Player(instance: TestInstance.shared)
      player.sendTeletextKey(.red)
      player.sendTeletextKey(.green)
      player.sendTeletextKey(.yellow)
      player.sendTeletextKey(.blue)
      player.sendTeletextKey(.index)
    }

    // MARK: - setRate

    @Test
    func `setRate positive value succeeds`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.setRate(1.0)
      try player.setRate(0.5)
      try player.setRate(2.0)
    }

    /// SwiftVLC no longer exposes libVLC's raw `set_rate(0)` quirk. The
    /// typed rate clamps invalid low values before they reach libVLC.
    @Test
    func `setRate zero is clamped by typed PlaybackRate`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.setRate(PlaybackRate(0))
      #expect(player.playbackRate == .slowest)
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
}
