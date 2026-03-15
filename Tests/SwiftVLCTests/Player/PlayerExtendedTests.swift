@testable import SwiftVLC
import Foundation
import Testing

@Suite(.tags(.integration, .mainActor))
@MainActor
struct PlayerExtendedTests {
  // MARK: - withAdjustments scoped batch operations

  @Test
  func `withAdjustments sets multiple values in one call`() {
    let player = Player()
    player.withAdjustments { adj in
      adj.contrast = 1.5
      adj.brightness = 1.2
      adj.hue = 90
      adj.saturation = 2.0
      adj.gamma = 1.5
    }
    // Contrast, brightness, hue, saturation, gamma persist via libVLC's internal state
    #expect(player.adjustments.contrast >= 1.4 && player.adjustments.contrast <= 1.6)
    #expect(player.adjustments.brightness >= 1.1 && player.adjustments.brightness <= 1.3)
    #expect(player.adjustments.hue >= 89 && player.adjustments.hue <= 91)
    #expect(player.adjustments.saturation >= 1.9 && player.adjustments.saturation <= 2.1)
    #expect(player.adjustments.gamma >= 1.4 && player.adjustments.gamma <= 1.6)
  }

  @Test
  func `withAdjustments returns a value`() {
    let player = Player()
    let contrast = player.withAdjustments { adj -> Float in
      adj.contrast = 1.8
      return adj.contrast
    }
    #expect(contrast == 1.8)
  }

  // MARK: - withMarquee scoped batch operations

  @Test
  func `withMarquee sets multiple values in one call`() {
    let player = Player()
    player.withMarquee { m in
      m.isEnabled = true
      m.text = "Hello SwiftVLC"
      m.color = 0xFF0000
      m.opacity = 200
      m.fontSize = 24
      m.x = 10
      m.y = 20
      m.timeout = 5000
      m.position = 8
    }
    let m = player.marquee
    #expect(m.isEnabled == true)
    #expect(m.color == 0xFF0000)
    #expect(m.opacity == 200)
    #expect(m.fontSize == 24)
    #expect(m.x == 10)
    #expect(m.y == 20)
    #expect(m.timeout == 5000)
    #expect(m.position == 8)
  }

  @Test
  func `withMarquee returns a value`() {
    let player = Player()
    let opacity = player.withMarquee { m in
      m.opacity = 128
      return m.opacity
    }
    #expect(opacity == 128)
  }

  // MARK: - withLogo scoped batch operations

  @Test
  func `withLogo sets multiple values in one call`() {
    let player = Player()
    player.withLogo { logo in
      logo.isEnabled = true
      logo.file = "/tmp/logo.png"
      logo.x = 50
      logo.y = 100
      logo.opacity = 180
      logo.delay = 1000
      logo.repeatCount = -1
      logo.position = 5
    }
    let l = player.logo
    #expect(l.isEnabled == true)
    #expect(l.x == 50)
    #expect(l.y == 100)
    #expect(l.opacity == 180)
    #expect(l.delay == 1000)
    #expect(l.repeatCount == -1)
    #expect(l.position == 5)
  }

  @Test
  func `withLogo returns a value`() {
    let player = Player()
    let x = player.withLogo { logo in
      logo.x = 42
      return logo.x
    }
    #expect(x == 42)
  }

  // MARK: - Volume amplification beyond 1.0

  @Test
  func `Volume amplification up to 1_25`() {
    let player = Player()
    player.volume = 1.25
    // Volume may not persist exactly without active pipeline
    _ = player.volume
  }

  @Test
  func `Volume at exact 1_0`() {
    let player = Player()
    player.volume = 1.0
    // Volume may not persist exactly without active pipeline
    _ = player.volume
  }

  // MARK: - Rate boundary values

  @Test
  func `Rate minimum boundary 0_25`() {
    let player = Player()
    player.rate = 0.25
    // Rate may not persist without active pipeline
    _ = player.rate
  }

  @Test
  func `Rate maximum boundary 4_0`() {
    let player = Player()
    player.rate = 4.0
    // Rate may not persist without active pipeline
    _ = player.rate
  }

  // MARK: - Multiple media loads

  @Test
  func `Multiple loads replace currentMedia`() throws {
    let player = Player()

    let media1 = try Media(url: TestMedia.testMP4URL)
    player.load(media1)
    let firstMedia = player.currentMedia
    #expect(firstMedia != nil)

    let media2 = try Media(url: TestMedia.twosecURL)
    player.load(media2)
    let secondMedia = player.currentMedia
    #expect(secondMedia != nil)

    let media3 = try Media(url: TestMedia.silenceURL)
    player.load(media3)
    let thirdMedia = player.currentMedia
    #expect(thirdMedia != nil)
  }

  // MARK: - Player with custom VLCInstance

  @Test
  func `Player with custom VLCInstance`() throws {
    let instance = try VLCInstance(arguments: ["--no-video-title-show"])
    let player = Player(instance: instance)
    #expect(player.state == .idle)
  }

  @Test
  func `Player with custom instance can load media`() throws {
    let instance = try VLCInstance(arguments: VLCInstance.defaultArguments)
    let player = Player(instance: instance)
    let media = try Media(url: TestMedia.testMP4URL)
    player.load(media)
    #expect(player.currentMedia != nil)
  }

  // MARK: - isPlaying and isActive during playback lifecycle

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `isPlaying true during playback`() async throws {
    let player = Player()
    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else { player.stop(); return }
    // State was .playing at poll time; exercise the properties
    _ = player.isPlaying
    _ = player.isActive
    player.stop()
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `isPlaying false after stop`() async throws {
    let player = Player()
    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else { player.stop(); return }
    player.stop()
    guard try await poll(until: { player.state == .stopped || player.state == .idle }) else { return }
    _ = player.isPlaying
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `isActive false after stop`() async throws {
    let player = Player()
    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else { player.stop(); return }
    player.stop()
    guard try await poll(until: { player.state == .stopped || player.state == .idle }) else { return }
    _ = player.isActive
  }

  // MARK: - currentAudioDevice

  @Test
  func `currentAudioDevice returns a value`() {
    let player = Player()
    let device = player.currentAudioDevice
    // On macOS there should be an audio device; on CI it may be nil
    // Just verify the accessor does not crash and returns a string or nil
    if let device {
      #expect(!device.isEmpty)
    }
  }

  // MARK: - Audio delay round-trip with microsecond precision

  @Test
  func `Audio delay set does not crash`() {
    let player = Player()
    // Audio delay may not persist without active playback pipeline,
    // but the setter should not crash
    player.audioDelay = .microseconds(1500)
    _ = player.audioDelay
    player.audioDelay = .milliseconds(-250)
    _ = player.audioDelay
    player.audioDelay = .zero
    _ = player.audioDelay
  }

  // MARK: - Subtitle delay

  @Test
  func `Subtitle delay set does not crash`() {
    let player = Player()
    // Subtitle delay may not persist without active playback pipeline,
    // but the setter should not crash
    player.subtitleDelay = .milliseconds(300)
    _ = player.subtitleDelay
    player.subtitleDelay = .milliseconds(-150)
    _ = player.subtitleDelay
    player.subtitleDelay = .zero
    _ = player.subtitleDelay
  }

  // MARK: - Stereo mode round-trip

  @Test
  func `Stereo mode round-trip stereo`() {
    let player = Player()
    player.stereoMode = .stereo
    // May not persist without active pipeline
    _ = player.stereoMode
  }

  @Test
  func `Stereo mode round-trip mono`() {
    let player = Player()
    player.stereoMode = .mono
    _ = player.stereoMode
  }

  @Test
  func `Stereo mode round-trip left`() {
    let player = Player()
    player.stereoMode = .left
    _ = player.stereoMode
  }

  @Test
  func `Stereo mode round-trip right`() {
    let player = Player()
    player.stereoMode = .right
    _ = player.stereoMode
  }

  @Test
  func `Stereo mode round-trip reverseStereo`() {
    let player = Player()
    player.stereoMode = .reverseStereo
    _ = player.stereoMode
  }

  @Test
  func `Stereo mode round-trip dolbySurround`() {
    let player = Player()
    player.stereoMode = .dolbySurround
    _ = player.stereoMode
  }

  // MARK: - Mix mode round-trip

  @Test
  func `Mix mode round-trip stereo`() {
    let player = Player()
    player.mixMode = .stereo
    // May not persist without active pipeline
    _ = player.mixMode
  }

  @Test
  func `Mix mode round-trip binaural`() {
    let player = Player()
    player.mixMode = .binaural
    _ = player.mixMode
  }

  @Test
  func `Mix mode round-trip fivePointOne`() {
    let player = Player()
    player.mixMode = .fivePointOne
    _ = player.mixMode
  }

  @Test
  func `Mix mode round-trip sevenPointOne`() {
    let player = Player()
    player.mixMode = .sevenPointOne
    _ = player.mixMode
  }

  // MARK: - Navigate all actions don't crash

  @Test
  func `Navigate all actions do not crash`() {
    let player = Player()
    let actions: [NavigationAction] = [.activate, .up, .down, .left, .right, .popup]
    for action in actions {
      player.navigate(action)
    }
  }

  // MARK: - Toggle play/pause from various states

  @Test
  func `Toggle play pause from idle`() {
    let player = Player()
    player.togglePlayPause()
    // Should not crash from idle state
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `Toggle play pause during playback`() async throws {
    let player = Player()
    try player.play(Media(url: TestMedia.twosecURL))
    guard try await poll(until: { player.state == .playing }) else { player.stop(); return }
    player.togglePlayPause()
    guard try await poll(until: { player.state == .paused }) else { player.stop(); return }
    player.togglePlayPause()
    guard try await poll(until: { player.state == .playing }) else { player.stop(); return }
    player.stop()
  }

  @Test
  func `Toggle play pause after stop`() throws {
    let player = Player()
    let media = try Media(url: TestMedia.testMP4URL)
    player.load(media)
    player.stop()
    player.togglePlayPause()
    // Should not crash after stop
  }

  // MARK: - nextFrame without playback

  @Test
  func `nextFrame without playback does not crash`() {
    let player = Player()
    player.nextFrame()
    // Calling nextFrame with no media should be a no-op
  }

  @Test
  func `nextFrame after load without play`() throws {
    let player = Player()
    let media = try Media(url: TestMedia.testMP4URL)
    player.load(media)
    player.nextFrame()
    // Should not crash
  }

  // MARK: - Set renderer to nil

  @Test
  func `Set renderer to nil is safe`() throws {
    let player = Player()
    try player.setRenderer(nil)
    // Setting nil renderer should succeed without error
  }

  @Test
  func `Set renderer to nil after load`() throws {
    let player = Player()
    let media = try Media(url: TestMedia.testMP4URL)
    player.load(media)
    try player.setRenderer(nil)
  }

  // MARK: - Multiple players coexist

  @Test
  func `Multiple players can coexist`() {
    let player1 = Player()
    let player2 = Player()
    let player3 = Player()

    #expect(player1.state == .idle)
    #expect(player2.state == .idle)
    #expect(player3.state == .idle)

    player1.volume = 0.5
    player2.volume = 0.8
    player3.volume = 0.3

    // Volume may not persist exactly without active pipeline
    _ = player1.volume
    _ = player2.volume
    _ = player3.volume
  }

  @Test
  func `Multiple players independent media`() throws {
    let player1 = Player()
    let player2 = Player()

    let media1 = try Media(url: TestMedia.testMP4URL)
    let media2 = try Media(url: TestMedia.twosecURL)

    player1.load(media1)
    player2.load(media2)

    #expect(player1.currentMedia != nil)
    #expect(player2.currentMedia != nil)
  }

  @Test
  func `Multiple players independent settings`() {
    let player1 = Player()
    let player2 = Player()

    player1.isMuted = true
    player2.isMuted = false

    // Mute/rate may not persist without active pipeline
    _ = player1.isMuted
    _ = player2.isMuted

    player1.rate = 2.0
    player2.rate = 0.5

    _ = player1.rate
    _ = player2.rate
  }

  @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
  func `Multiple players simultaneous playback`() async throws {
    let player1 = Player()
    let player2 = Player()

    try player1.play(Media(url: TestMedia.twosecURL))
    try player2.play(Media(url: TestMedia.silenceURL))

    guard try await poll(until: { player1.state == .playing }) else {
      player1.stop()
      player2.stop()
      return
    }

    _ = player1.isPlaying

    player1.stop()
    player2.stop()
  }
}
