@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Integration {
  /// libVLC issues an A-B loop's seeks itself, outside the wrapper's seek
  /// lane. One that starts while a wrapper seek is still unresolved cannot be
  /// told apart from it; that used to close the observable clock and the lane
  /// until the next stop or load.
  @Suite(.tags(.mainActor, .async, .media), .timeLimit(.minutes(1)))
  @MainActor struct ABLoopPlaybackTests {
    @Test(.enabled(if: TestCondition.canPlayMedia, "Requires real playback"))
    func `a loop armed behind an unresolved seek keeps the clock and the lane live`() async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "frame-index", withExtension: "mp4", subdirectory: "Fixtures/seek-oracle"
      ))
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--quiet"]
      )
      let player = Player(instance: instance)
      do {
        try player.play(url: fixtureURL)
        try #require(await poll(timeout: .seconds(5)) {
          player.state == .playing && player.isSeekable && player.currentTime > .milliseconds(300)
        })

        // Playback is outside [a, b], so libVLC seeks to `a` inside the
        // setter while the wrapper seek issued just before it is in flight.
        try player.seek(to: .seconds(20))
        try player.setABLoop(a: .seconds(20), b: .seconds(25))
        #expect(player.abLoopState == .active)

        let advancedInsideLoop = try await poll(timeout: .seconds(3)) {
          player.currentTime > .milliseconds(20300) && player.currentTime < .seconds(25)
        }
        #expect(advancedInsideLoop, "published time stayed at \(player.currentTime)")
        #expect(!player.nativeSeekMonitor.hasSeekDrainPending)

        let clock = ContinuousClock()
        let start = clock.now
        let request = try player.requestSeek(to: .seconds(22))
        #expect(await request.outcome == .settled)
        #expect(clock.now - start < .seconds(1))
        #expect(abs(libvlc_media_player_get_time(player.pointer) - 22000) < 1500)
      } catch { await player.shutdown(); throw error }
      await player.shutdown()
    }
  }
}
