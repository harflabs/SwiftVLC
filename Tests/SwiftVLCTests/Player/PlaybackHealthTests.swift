@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PlaybackHealthTests {
    @Test
    func `First decoded and presented frame fire exactly once per generation`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      player.activeVideoOutputs = 1
      let events = player.playbackHealthEvents
      let now = ContinuousClock.now

      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(decodedVideoFrames: 1),
        now: now
      )
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedVideoFrames: 2,
          presentedVideoFrames: 1
        ),
        now: now.advanced(by: .milliseconds(10))
      )
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedVideoFrames: 2,
          presentedVideoFrames: 1
        ),
        now: now.advanced(by: .milliseconds(20))
      )

      let firstGeneration = player.generation
      try player.load(Media(url: TestMedia.testMP4URL))
      player.state = .playing
      player.activeVideoOutputs = 1
      let newGenerationEvents = player.playbackHealthEvents
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedVideoFrames: 1,
          presentedVideoFrames: 1
        ),
        now: now.advanced(by: .milliseconds(30))
      )
      player.playbackHealthEventBridge.terminate()

      var received: [PlaybackHealthEventKind] = []
      for await event in events {
        received.append(event.kind)
      }
      var receivedAfterBoundary: [PlaybackHealthEvent] = []
      for await event in newGenerationEvents {
        receivedAfterBoundary.append(event)
      }
      #expect(received.filter { $0 == .firstDecodedFrame }.count == 2)
      #expect(received.filter { $0 == .firstPresentedFrame }.count == 2)
      #expect(receivedAfterBoundary.count == 2)
      #expect(receivedAfterBoundary.allSatisfy { $0.snapshot.generation == player.generation })
      #expect(player.playbackHealth.state == .healthy(.videoOnly))
      #expect(player.playbackHealth.generation == player.generation)
      #expect(player.generation > firstGeneration)
    }

    @Test
    func `A recovered stall remains paired for late subscribers`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      player.activeVideoOutputs = 1
      let now = ContinuousClock.now
      let initial = PlaybackHealthCounters(
        sourceReadBytes: 100,
        decodedVideoFrames: 10,
        presentedVideoFrames: 5
      )
      player._applyPlaybackHealthSampleForTesting(counters: initial, now: now)

      player.playbackHealthMonitoringState.previousCounters = initial
      player.playbackHealthMonitoringState.lastSourceProgressAt = now
      player.playbackHealthMonitoringState.lastDecodedProgressAt = now
      player.playbackHealthMonitoringState.lastPresentedProgressAt = now.advanced(by: .seconds(-3))
      player._applyPlaybackHealthSampleForTesting(
        counters: initial,
        now: now.advanced(by: .milliseconds(10))
      )
      #expect(player.playbackHealth.state == .stalled(.display))

      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          sourceReadBytes: 100,
          decodedVideoFrames: 11,
          presentedVideoFrames: 6
        ),
        now: now.advanced(by: .milliseconds(20))
      )
      #expect(player.playbackHealth.state == .healthy(.videoOnly))

      let snapshots = player.playbackHealthSnapshots
      let events = player.playbackHealthEvents
      player.playbackHealthSnapshotBridge.terminate()
      player.playbackHealthEventBridge.terminate()

      var replayedSnapshot: PlaybackHealthSnapshot?
      for await snapshot in snapshots {
        replayedSnapshot = snapshot
      }
      var replayedEvent: PlaybackHealthEvent?
      for await event in events {
        replayedEvent = event
      }
      #expect(replayedSnapshot?.lastStallReason == .display)
      #expect(replayedSnapshot?.lastStalledAt != nil)
      #expect(replayedSnapshot?.lastRecoveredAt != nil)
      #expect(replayedEvent?.kind == .recovered(from: .display))
    }

    @Test
    func `Expected waits remain distinct from stalls`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))

      player.state = .opening
      player._applyPlaybackHealthSampleForTesting(counters: PlaybackHealthCounters())
      #expect(player.playbackHealth.state == .waiting(.opening))

      player.state = .buffering
      player._applyPlaybackHealthSampleForTesting(counters: PlaybackHealthCounters())
      #expect(player.playbackHealth.state == .waiting(.buffering))

      player.state = .paused
      player._applyPlaybackHealthSampleForTesting(counters: PlaybackHealthCounters())
      #expect(player.playbackHealth.state == .paused)
    }

    @Test
    func `Seek and adaptive switch waits clear when presentation advances`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      player.activeVideoOutputs = 1
      let initial = PlaybackHealthCounters(
        decodedVideoFrames: 1,
        presentedVideoFrames: 1
      )
      player._applyPlaybackHealthSampleForTesting(counters: initial)

      player.markPlaybackHealthSeek()
      #expect(player.playbackHealth.state == .waiting(.seeking))
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedVideoFrames: 2,
          presentedVideoFrames: 2
        )
      )
      #expect(player.playbackHealth.state == .healthy(.videoOnly))

      player.markPlaybackHealthAdaptiveSwitch()
      #expect(player.playbackHealth.state == .waiting(.adaptiveSwitch))
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedVideoFrames: 3,
          presentedVideoFrames: 3
        )
      )
      #expect(player.playbackHealth.state == .healthy(.videoOnly))
    }

    @Test
    func `Paused playback clears a pending wait and sampler`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      player.activeVideoOutputs = 1
      player.markPlaybackHealthSeek()
      #expect(player.playbackHealthMonitoringState.pendingWaitingReason == .seeking)

      player.state = .paused
      player._applyPlaybackHealthSampleForTesting(counters: PlaybackHealthCounters())
      player.reconcilePlaybackHealthSamplingTask()

      #expect(player.playbackHealth.state == .paused)
      #expect(player.playbackHealthMonitoringState.pendingWaitingReason == nil)
      #expect(player.playbackHealthSamplingTask == nil)
    }

    @Test
    func `Paused renderer recovery remains observable and paired`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .paused
      let events = player.playbackHealthEvents
      let now = ContinuousClock.now

      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(rendererFlushes: 1),
        renderer: PlaybackRendererHealthSample(
          playbackGeneration: player.sessionGeneration,
          flushes: 1,
          status: .recovering
        ),
        now: now
      )
      #expect(player.playbackHealth.state == .stalled(.rendererRecovery))

      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          presentedVideoFrames: 1,
          rendererFlushes: 1
        ),
        renderer: PlaybackRendererHealthSample(
          playbackGeneration: player.sessionGeneration,
          presentedFrames: 1,
          flushes: 1,
          lastPresentedAt: now.advanced(by: .milliseconds(20)),
          status: .rendering
        ),
        now: now.advanced(by: .milliseconds(20))
      )
      player.playbackHealthEventBridge.terminate()

      var received: [PlaybackHealthEventKind] = []
      for await event in events {
        received.append(event.kind)
      }
      #expect(received.filter { $0 == .stalled(.rendererRecovery) }.count == 1)
      #expect(received.filter { $0 == .recovered(from: .rendererRecovery) }.count == 1)
      #expect(player.playbackHealth.state == .paused)
    }

    @Test
    func `Renderer recovery failure remains terminal after renderer status changes`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      let now = ContinuousClock.now
      let failed = PlaybackHealthCounters(rendererRecoveryFailures: 1)

      player._applyPlaybackHealthSampleForTesting(
        counters: failed,
        renderer: PlaybackRendererHealthSample(
          playbackGeneration: player.sessionGeneration,
          recoveryFailures: 1,
          status: .failed
        ),
        now: now
      )
      #expect(player.playbackHealth.state == .failed(.renderer))

      player._applyPlaybackHealthSampleForTesting(
        counters: failed,
        renderer: PlaybackRendererHealthSample(
          playbackGeneration: player.sessionGeneration,
          recoveryFailures: 1,
          status: .rendering
        ),
        now: now.advanced(by: .seconds(1))
      )
      #expect(player.playbackHealth.state == .failed(.renderer))
    }

    @Test
    func `Recovery remains paired when an expected wait intervenes`() async throws {
      let player = try makePlayerForStall()
      let events = player.playbackHealthEvents
      let now = ContinuousClock.now
      let stalled = PlaybackHealthCounters(
        sourceReadBytes: 100,
        decodedVideoFrames: 10,
        presentedVideoFrames: 1
      )
      player.playbackHealthMonitoringState.previousCounters = stalled
      player.playbackHealthMonitoringState.lastSourceProgressAt = now
      player.playbackHealthMonitoringState.lastDecodedProgressAt = now
      player.playbackHealthMonitoringState.lastPresentedProgressAt = now.advanced(by: .seconds(-3))
      player._applyPlaybackHealthSampleForTesting(counters: stalled, now: now)
      #expect(player.playbackHealth.state == .stalled(.display))

      player.markPlaybackHealthAdaptiveSwitch()
      #expect(player.playbackHealth.state == .waiting(.adaptiveSwitch))
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          sourceReadBytes: 100,
          decodedVideoFrames: 11,
          presentedVideoFrames: 2
        ),
        now: now.advanced(by: .milliseconds(20))
      )
      #expect(player.playbackHealth.state == .healthy(.videoOnly))

      player.playbackHealthEventBridge.terminate()
      var received: [PlaybackHealthEventKind] = []
      for await event in events {
        received.append(event.kind)
      }
      #expect(received.contains(.stalled(.display)))
      #expect(received.contains(.recovered(from: .display)))
    }

    @Test
    func `Entering playing rearms progress clocks after intentional inactivity`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .paused
      let stale = ContinuousClock.now.advanced(by: .seconds(-30))
      player.playbackHealthMonitoringState.lastSourceProgressAt = stale
      player.playbackHealthMonitoringState.lastDecodedProgressAt = stale
      player.playbackHealthMonitoringState.lastAudioDecodedProgressAt = stale
      player.playbackHealthMonitoringState.lastPresentedProgressAt = stale
      player.playbackHealthMonitoringState.lastAudioProgressAt = stale

      player.publishPlaybackState(.playing)

      let now = ContinuousClock.now
      #expect(
        player.playbackHealthMonitoringState.lastSourceProgressAt.duration(to: now)
          < .seconds(1)
      )
      #expect(
        player.playbackHealthMonitoringState.lastPresentedProgressAt.duration(to: now)
          < .seconds(1)
      )
      #expect(player.playbackHealth.state != .stalled(.source))
    }

    @Test
    func `Audiovisual health requires selected audio output progress`() throws {
      let player = try makePlayerForStall()
      player.audioTracks = [makeAudioTrack(isSelected: true)]
      let now = ContinuousClock.now
      let counters = PlaybackHealthCounters(
        sourceReadBytes: 100,
        decodedVideoFrames: 10,
        decodedAudioFrames: 10,
        presentedVideoFrames: 5,
        playedAudioBuffers: 2
      )
      player.playbackHealthMonitoringState.previousCounters = counters
      player.playbackHealthMonitoringState.lastSourceProgressAt = now
      player.playbackHealthMonitoringState.lastDecodedProgressAt = now
      player.playbackHealthMonitoringState.lastAudioDecodedProgressAt = now
      player.playbackHealthMonitoringState.lastPresentedProgressAt = now
      player.playbackHealthMonitoringState.lastAudioProgressAt = now.advanced(by: .seconds(-3))

      player._applyPlaybackHealthSampleForTesting(counters: counters, now: now)

      #expect(player.playbackHealth.state == .stalled(.audioOutput))
    }

    @Test
    func `Unselected audio does not turn video-only playback audiovisual`() throws {
      let player = try makePlayerForStall()
      player.audioTracks = [makeAudioTrack(isSelected: false)]
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedVideoFrames: 2,
          presentedVideoFrames: 1
        )
      )

      #expect(player.playbackHealth.state == .healthy(.videoOnly))
    }

    @Test
    func `Adaptive video comparison notices metadata changes with the same track ID`() {
      let original = makeVideoTrack(width: 1280, frameRate: 24)
      let identical = makeVideoTrack(width: 1280, frameRate: 24)
      let adapted = makeVideoTrack(width: 1920, frameRate: 30)

      #expect(!Player.playbackHealthVideoTracksDiffer([original], [identical]))
      #expect(Player.playbackHealthVideoTracksDiffer([original], [adapted]))
    }

    @Test
    func `Pipeline counters identify source decoder display and audio-output stalls`() throws {
      let source = try makePlayerForStall()
      let now = ContinuousClock.now
      source.playbackHealthMonitoringState.activePlaybackBeganAt = now.advanced(by: .seconds(-3))
      source.playbackHealthMonitoringState.lastSourceProgressAt = now.advanced(by: .seconds(-3))
      source.playbackHealthMonitoringState.lastDecodedProgressAt = now.advanced(by: .seconds(-3))
      source.playbackHealthMonitoringState.lastPresentedProgressAt = now.advanced(by: .seconds(-3))
      source._applyPlaybackHealthSampleForTesting(counters: PlaybackHealthCounters(), now: now)
      #expect(source.playbackHealth.state == .stalled(.source))

      let decoder = try makePlayerForStall()
      let decoderCounters = PlaybackHealthCounters(sourceReadBytes: 100)
      decoder.playbackHealthMonitoringState.activePlaybackBeganAt = now.advanced(by: .seconds(-3))
      decoder.playbackHealthMonitoringState.previousCounters = decoderCounters
      decoder.playbackHealthMonitoringState.lastSourceProgressAt = now
      decoder.playbackHealthMonitoringState.lastDecodedProgressAt = now.advanced(by: .seconds(-3))
      decoder.playbackHealthMonitoringState.lastPresentedProgressAt = now.advanced(by: .seconds(-3))
      decoder._applyPlaybackHealthSampleForTesting(counters: decoderCounters, now: now)
      #expect(decoder.playbackHealth.state == .stalled(.decoder))

      let display = try makePlayerForStall()
      let displayCounters = PlaybackHealthCounters(
        sourceReadBytes: 100,
        decodedVideoFrames: 10,
        presentedVideoFrames: 1
      )
      display.playbackHealthMonitoringState.activePlaybackBeganAt = now.advanced(by: .seconds(-3))
      display.playbackHealthMonitoringState.previousCounters = displayCounters
      display.playbackHealthMonitoringState.lastSourceProgressAt = now
      display.playbackHealthMonitoringState.lastDecodedProgressAt = now
      display.playbackHealthMonitoringState.lastPresentedProgressAt = now.advanced(by: .seconds(-3))
      display._applyPlaybackHealthSampleForTesting(counters: displayCounters, now: now)
      #expect(display.playbackHealth.state == .stalled(.display))

      let audio = Player(instance: TestInstance.makeAudioOnly())
      try audio.load(Media(url: TestMedia.twosecURL))
      audio.state = .playing
      let audioCounters = PlaybackHealthCounters(
        sourceReadBytes: 100,
        decodedAudioFrames: 10
      )
      audio.playbackHealthMonitoringState.activePlaybackBeganAt = now.advanced(by: .seconds(-3))
      audio.playbackHealthMonitoringState.previousCounters = audioCounters
      audio.playbackHealthMonitoringState.lastSourceProgressAt = now
      audio.playbackHealthMonitoringState.lastAudioDecodedProgressAt = now
      audio.playbackHealthMonitoringState.lastAudioProgressAt = now.advanced(by: .seconds(-3))
      audio._applyPlaybackHealthSampleForTesting(counters: audioCounters, now: now)
      #expect(audio.playbackHealth.state == .stalled(.audioOutput))
    }

    @Test
    func `Audio-only progress is healthy without a video presentation`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      player._applyPlaybackHealthSampleForTesting(
        counters: PlaybackHealthCounters(
          decodedAudioFrames: 2,
          playedAudioBuffers: 1
        )
      )
      #expect(player.playbackHealth.state == .healthy(.audioOnly))
      #expect(player.playbackHealth.lastPresentedAt == nil)
    }

    private func makePlayerForStall() throws -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player.state = .playing
      player.activeVideoOutputs = 1
      return player
    }

    private func makeAudioTrack(isSelected: Bool) -> Track {
      Track(
        id: "audio-0",
        type: .audio,
        name: "Audio",
        codec: 0,
        language: nil,
        trackDescription: nil,
        isSelected: isSelected,
        bitrate: 0,
        channels: 2,
        sampleRate: 48000,
        width: nil,
        height: nil,
        frameRate: nil,
        frameRateRatio: nil,
        encoding: nil
      )
    }

    private func makeVideoTrack(width: Int, frameRate: Double) -> Track {
      Track(
        id: "video-0",
        type: .video,
        name: "Video",
        codec: 0,
        language: nil,
        trackDescription: nil,
        isSelected: true,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: width,
        height: 720,
        frameRate: frameRate,
        frameRateRatio: nil,
        encoding: nil
      )
    }
  }
}
