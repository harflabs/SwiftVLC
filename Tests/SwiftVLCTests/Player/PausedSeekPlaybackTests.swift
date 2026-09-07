@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Integration.RemoteMP4SeekTests {
  @Test(.timeLimit(.minutes(1)), arguments: [true, false], [true, false])
  func `Paused HTTP seeks settle at the output and retain that clock`(fast: Bool, audio: Bool) async throws {
    let fixtureURL = try #require(Bundle.module.url(
      forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
    ))
    let server = try MP4RangeProbeServer(data: Data(contentsOf: fixtureURL))
    defer { server.stop() }
    let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
      "--vout=dummy", "--aout=dummy", "--no-hw-dec", "--quiet",
      audio ? "--audio" : "--no-audio"
    ])
    let player = Player(instance: instance)
    defer { player.stop() }
    try player.play(url: server.url)
    try #require(await poll(every: .milliseconds(50), timeout: .seconds(10)) {
      player.state == .playing && player.isSeekable && player.currentTime >= .seconds(2)
    })
    player.pause()
    try #require(await poll(every: .milliseconds(50), timeout: .seconds(3)) {
      player.state == .paused
    })
    // Paused wall time must not be counted as input clock lateness after seek.
    try await Task.sleep(for: .seconds(1))
    let start = player.currentTime
    let forward = try player.requestSeek(by: .seconds(10), fast: fast)
    try await assertLanding(forward, target: start + .seconds(10), fast: fast, player: player)
    let afterForward = player.currentTime
    let backward = try player.requestSeek(by: .seconds(-5), fast: fast)
    try await assertLanding(backward, target: afterForward - .seconds(5), fast: fast, player: player)
    let position = player.requestSeek(toPosition: PlaybackPosition(0.7), fast: fast)
    try await assertLanding(position, target: .seconds(14), fast: fast, player: player)
    let absolute = try player.requestSeek(to: .milliseconds(5400), fast: fast)
    try await assertLanding(absolute, target: .milliseconds(5400), fast: fast, player: player)
    let pausedTime = player.currentTime
    player.resume()
    try #require(await poll(every: .milliseconds(50), timeout: .seconds(5)) {
      player.state == .playing && player.currentTime >= pausedTime + .milliseconds(500)
    })
    #expect(player.currentTime < pausedTime + .seconds(5))
  }

  private func assertLanding(
    _ request: SeekRequest, target: Duration, fast: Bool, player: Player
  )
    async throws {
    let outcome = await request.outcome
    try #require(outcome == .settled, "Target \(target), mirror \(player.currentTime), native \(libvlc_media_player_get_time(player.pointer))")
    // Assert at settlement, before any later raw event can conceal a false
    // success from the pre-seek getter. Fast seeks may land at the prior IDR.
    let landed = player.currentTime
    let tolerance: Duration = fast ? .milliseconds(2100) : .milliseconds(150)
    #expect(landed >= target - tolerance)
    #expect(landed <= target + .milliseconds(150))
    let nativeLanded = libvlc_media_player_get_time(player.pointer)
    #expect(landed >= .milliseconds(nativeLanded - 100))
    #expect(landed <= .milliseconds(nativeLanded + 100))
    try await Task.sleep(for: .milliseconds(1500))
    #expect(player.state == .paused)
    #expect(abs(libvlc_media_player_get_time(player.pointer) - nativeLanded) <= 100)
    #expect(player.currentTime >= landed - .milliseconds(100))
    #expect(player.currentTime <= landed + .milliseconds(100))
  }
}
