@testable import SwiftVLC
import Testing

/// Covers Player branches that require media to be loaded but NOT
/// played (the environment can't reach `.playing`). Loading media is
/// enough to exercise the success paths of `setABLoop`, rate, audio
/// delay, etc., which without media fail at the libVLC layer.
extension Integration {
  @Suite(.tags(.mainActor, .media))
  @MainActor struct PlayerWithMediaBranchTests {
    @Test
    func `setABLoop by time succeeds with media loaded`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      // With media loaded, libVLC accepts A-B loop even before playing.
      // If this throws, libVLC changed its API contract; pin the
      // current behavior so that shows up as a test failure.
      try player.setABLoop(a: .milliseconds(100), b: .milliseconds(500))
    }

    @Test
    func `setABLoop by position succeeds with media loaded`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      try player.setABLoop(aPosition: 0.1, bPosition: 0.5)
    }

    /// `resetABLoop` requires the player to be actively playing or
    /// paused; libVLC rejects the reset before playback starts. Pin
    /// the error shape so a future libVLC that relaxes the contract
    /// is a visible test surprise.
    @Test
    func `resetABLoop without playback throws`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      try player.setABLoop(a: .milliseconds(100), b: .milliseconds(500))
      #expect(throws: VLCError.self) {
        try player.resetABLoop()
      }
    }

    /// Reading `abLoopState` before and after `setABLoop` exercises
    /// the `access(keyPath:)` registration so the observation graph
    /// picks up the subsequent mutation. libVLC only promotes the
    /// state out of `.none` during active playback, which we can't
    /// reach headlessly, so we pin that `.none` is reported at both
    /// points (no crash, idempotent read).
    @Test
    func `abLoopState can be read before and after setABLoop`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      #expect(player.abLoopState == .none)
      try player.setABLoop(a: .milliseconds(100), b: .milliseconds(500))
      #expect(player.abLoopState == .none, "libVLC leaves state at .none until playback starts")
    }

    /// Loading the same media twice re-invokes `load`, exercising the
    /// `currentMedia` replacement path and all the media-dependent
    /// observable notifications.
    @Test
    func `Loading media twice replaces currentMedia`() throws {
      let player = Player(instance: TestInstance.shared)

      let first = try Media(url: TestMedia.testMP4URL)
      player.load(first)
      #expect(player.currentMedia === first)

      let second = try Media(url: TestMedia.twosecURL)
      player.load(second)
      #expect(player.currentMedia === second)
    }

    /// Setting audioDelay on a player with media round-trips through
    /// libVLC and reflects on the next read.
    @Test
    func `audioDelay round trip with media loaded`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      player.audioDelay = .milliseconds(100)
      #expect(player.audioDelay == .milliseconds(100))
    }

    /// Setting subtitleDelay round-trips the same way.
    @Test
    func `subtitleDelay round trip with media loaded`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      player.subtitleDelay = .milliseconds(-200)
      #expect(player.subtitleDelay == .milliseconds(-200))
    }

    /// `addExternalTrack` with a valid file URL succeeds (media must
    /// be loaded for libVLC to accept the slave).
    @Test
    func `addExternalTrack with valid subtitle URL succeeds`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      // libVLC accepts any valid URL; the slave is deferred until
      // playback, so no error is surfaced here.
      try player.addExternalTrack(
        from: TestMedia.subtitleURL,
        type: .subtitle,
        select: true
      )
    }

    /// `statistics` is accessible on media even without reaching
    /// `.playing`; it returns zeros until real decoder work happens.
    @Test
    func `statistics accessible after load before play`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      _ = player.statistics
    }

    /// chapters(forTitle: -1) is the "current title" overload. With
    /// media loaded but no titles, it must return an empty array,
    /// not crash.
    @Test
    func `chapters(forTitle: -1) returns empty for non-structured media`() throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)

      #expect(player.chapters(forTitle: -1).isEmpty)
    }
  }
}
