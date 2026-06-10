@testable import SwiftVLC
import CoreGraphics
import Foundation
import Observation
import Synchronization
import Testing

/// Covers `videoSize`, `hasVideoOutput`, and `activeVideoOutputs` —
/// the decoded-video surface fed by `.voutChanged` and read live from
/// libVLC.
extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PlayerVideoInfoTests {
    // MARK: - Idle defaults (ungated)

    @Test
    func `fresh idle player reports no video output`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.videoSize == nil)
      #expect(player.hasVideoOutput == false)
      #expect(player.activeVideoOutputs == 0)
    }

    // MARK: - Observation (ungated)

    @Test
    func `voutChanged invalidates videoSize observation`() {
      let player = Player(instance: TestInstance.shared)
      let fired = Mutex(false)
      withObservationTracking {
        _ = player.videoSize
      } onChange: {
        fired.withLock { $0 = true }
      }
      player._handleEventForTesting(.voutChanged(1))
      #expect(fired.withLock { $0 })
    }

    @Test
    func `voutChanged invalidates hasVideoOutput observation`() {
      let player = Player(instance: TestInstance.shared)
      let fired = Mutex(false)
      withObservationTracking {
        _ = player.hasVideoOutput
      } onChange: {
        fired.withLock { $0 = true }
      }
      player._handleEventForTesting(.voutChanged(1))
      #expect(fired.withLock { $0 })
    }

    @Test
    func `tracksChanged invalidates videoSize observation`() {
      let player = Player(instance: TestInstance.shared)
      let fired = Mutex(false)
      withObservationTracking {
        _ = player.videoSize
      } onChange: {
        fired.withLock { $0 = true }
      }
      player._handleEventForTesting(.tracksChanged)
      #expect(fired.withLock { $0 })
    }

    @Test
    func `voutChanged stores the active output count`() {
      let player = Player(instance: TestInstance.shared)
      player._handleEventForTesting(.voutChanged(2))
      #expect(player.activeVideoOutputs == 2)
      player._handleEventForTesting(.voutChanged(0))
      #expect(player.activeVideoOutputs == 0)
    }
  }

  @Suite(.tags(.mainActor, .async), .enabled(if: TestCondition.canPlayMedia, "Requires video output"))
  @MainActor struct PlayerVideoInfoPlaybackTests {
    // MARK: - Video media

    @Test(.timeLimit(.minutes(1)))
    func `video playback reports decoded size and output presence`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      defer { player.stop() }

      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(every: .milliseconds(50), timeout: .seconds(5), until: { player.hasVideoOutput }),
        "Waiting for: hasVideoOutput == true"
      )
      try #require(
        await poll(until: { player.videoSize != nil }),
        "Waiting for: decoded video size published"
      )
      // `activeVideoOutputs` is fed by the event consumer and can trail
      // the live reads by a beat.
      try #require(
        await poll(until: { player.activeVideoOutputs >= 1 }),
        "Waiting for: activeVideoOutputs >= 1"
      )

      #expect(player.videoSize == CGSize(width: 64, height: 64))
      #expect(player.activeVideoOutputs >= 1)
    }

    // MARK: - Audio-only media

    @Test(.timeLimit(.minutes(1)))
    func `audio-only playback reports no video output`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      defer { player.stop() }

      try player.play(Media(url: TestMedia.silenceURL))
      // The 0.5 s fixture can reach its natural end before a poll for
      // `.playing` observes it; every state on that path keeps the
      // assertions below true, so wait for any evidence the session ran.
      try #require(
        await poll(until: { player.state == .playing || player.didReachEnd }),
        "Waiting for: playback started or finished"
      )

      #expect(player.videoSize == nil)
      #expect(player.hasVideoOutput == false)
      #expect(player.activeVideoOutputs == 0)
    }

    // MARK: - Reset across load()

    @Test(.timeLimit(.minutes(1)))
    func `loading new media resets the output count`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      defer { player.stop() }

      try player.play(Media(url: TestMedia.testMP4URL))
      try #require(
        await poll(every: .milliseconds(50), timeout: .seconds(5), until: { player.activeVideoOutputs >= 1 }),
        "Waiting for: activeVideoOutputs >= 1"
      )

      try player.load(Media(url: TestMedia.silenceURL))
      #expect(player.activeVideoOutputs == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `replacing the native player resets the output count`() throws {
      let player = Player(instance: TestInstance.makePlayback())
      defer { player.stop() }

      player._handleEventForTesting(.voutChanged(1))
      #expect(player.activeVideoOutputs == 1)

      // Stopping drawable-hosted playback marks the native handle for
      // lazy replacement; preparing the drawable then swaps the handle.
      // The old handle's closing `voutChanged(0)` is dropped by the
      // source filter after the swap, so the swap itself must reset the
      // mirrored count.
      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()
      #expect(player.activeVideoOutputs == 0)
    }
  }
}
