#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import Foundation
import Synchronization
import Testing

/// Exercises the `pipEvents` lifecycle stream on the sample-buffer
/// path by invoking the `AVPictureInPictureControllerDelegate`
/// callbacks directly — no real PiP window is needed, so everything
/// here runs headless. The `AVPictureInPictureController` argument is a
/// dummy the delegate methods never touch.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPEventsTests {
    /// The `AVPictureInPictureController` SwiftVLC actually installed.
    ///
    /// Delegate callbacks are rejected unless they come from the installed
    /// controller, so a freshly constructed instance would be treated as a
    /// replaced one and dropped. The fallback keeps that a clear assertion
    /// failure rather than a crash if no controller was installed.
    private func makeDummyAVController(for controller: PiPController) -> AVPictureInPictureController {
      if let installed = controller.pipController {
        return installed
      }
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      return AVPictureInPictureController(contentSource: contentSource)
    }

    /// Drains exactly `count` events from the stream. Subscriptions are
    /// unbounded, so events emitted before this call are buffered and
    /// yield immediately.
    private func collect(
      _ count: Int,
      from stream: AsyncStream<PiPEvent>
    )
      async -> [PiPEvent] {
      var collected: [PiPEvent] = []
      for await event in stream {
        collected.append(event)
        if collected.count == count {
          break
        }
      }
      return collected
    }

    private func collect(
      _ count: Int,
      from stream: AsyncStream<PiPEventEnvelope>
    )
      async -> [PiPEventEnvelope] {
      var collected: [PiPEventEnvelope] = []
      for await event in stream {
        collected.append(event)
        if collected.count == count {
          break
        }
      }
      return collected
    }

    @Test
    func `willStart and didStart delegate callbacks emit events`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      // Assert before the first suspension: once this task suspends, the
      // KVO mirror of the controller's own (inactive) AVKit instance is
      // free to resync the flag.
      #expect(controller.isActive)

      let events = await collect(2, from: stream)
      guard case .willStart = events[0] else {
        Issue.record("Expected .willStart, got \(events[0])")
        return
      }
      guard case .didStart = events[1] else {
        Issue.record("Expected .didStart, got \(events[1])")
        return
      }
    }

    @Test
    func `failedToStart carries the delegate error`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let failure = NSError(domain: "swiftvlc.test.pip", code: 42)

      controller._setStateForTesting(isActive: true)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      let events = await collect(1, from: stream)
      guard case .failedToStart(let error) = events[0] else {
        Issue.record("Expected .failedToStart, got \(events[0])")
        return
      }
      let nsError = error as NSError
      #expect(nsError.domain == "swiftvlc.test.pip")
      #expect(nsError.code == 42)
      // failedToStart must also resync isActive to false.
      #expect(controller.isActive == false)
    }

    @Test
    func `An accepted start failure retains its controller and media generation`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let acceptedMediaGeneration = player.generation
      let acceptedControllerGeneration = controller.pipControllerGeneration

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      try player.load(Media(url: TestMedia.silenceURL))
      #expect(player.generation > acceptedMediaGeneration)

      let failure = NSError(domain: "swiftvlc.test.pip.generation", code: 17)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == acceptedMediaGeneration)
      #expect(envelope.controllerGeneration == acceptedControllerGeneration)
      guard case .failedToStart(let error) = envelope.event else {
        Issue.record("Expected .failedToStart, got \(envelope.event)")
        return
      }
      #expect((error as NSError).code == 17)
    }

    @Test
    func `willStart does not steal an accepted request for successor media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let acceptedMediaGeneration = player.generation

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      try player.load(Media(url: TestMedia.silenceURL))
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      let envelopes = await collect(2, from: stream)
      #expect(envelopes.map(\.mediaGeneration) == [
        acceptedMediaGeneration,
        acceptedMediaGeneration
      ])
      #expect(envelopes.allSatisfy {
        $0.controllerGeneration == controller.pipControllerGeneration
      })
    }

    @Test
    func `A redundant accepted start does not steal an active lifecycle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let lifecycleMediaGeneration = player.generation

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      try player.load(Media(url: TestMedia.silenceURL))
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(3, from: stream)
      #expect(envelopes.allSatisfy {
        $0.mediaGeneration == lifecycleMediaGeneration
      })
    }

    @Test
    func `A late willStart remains with the attempt stopped before it began`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let stoppedMediaGeneration = player.generation

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.stop()
      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)

      let envelopes = await collect(4, from: stream)
      #expect(envelopes.prefix(3).allSatisfy {
        $0.mediaGeneration == stoppedMediaGeneration
      })
      #expect(envelopes[3].mediaGeneration == retryMediaGeneration)
    }

    @Test
    func `A fresh accepted start after failure captures the new media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failure = NSError(domain: "swiftvlc.test.pip.retry", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(4, from: stream)
      #expect(envelopes.dropFirst().allSatisfy {
        $0.mediaGeneration == retryMediaGeneration
      })
      guard case .didStop(reason: .userClosed) = envelopes[3].event else {
        Issue.record("Expected the successful retry's independent stop")
        return
      }
    }

    @Test
    func `An idle stop reason does not poison the next failed start retry`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failure = NSError(domain: "swiftvlc.test.pip.idle-stop", code: 1)

      controller.stop()
      #expect(controller.pendingStopReason == .unknown)
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      let envelopes = await collect(3, from: stream)
      #expect(envelopes.dropFirst().allSatisfy {
        $0.mediaGeneration == retryMediaGeneration
      })
      guard case .failedToStart = envelopes[0].event else {
        Issue.record("Expected the first attempt to fail")
        return
      }
    }

    @Test
    func `A failed attempt's trailing stop does not consume its accepted retry`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failedMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.overlapping-retry", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      try player.load(Media(url: TestMedia.twosecURL))
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)

      // AVKit may finish the failed lifecycle after the application has
      // already issued its retry and delivered willStart. That old stop must
      // consume only the saved failed identity, leaving the retry intact.
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(5, from: stream)
      #expect(envelopes[0].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[2].mediaGeneration == failedMediaGeneration)
      #expect([envelopes[1], envelopes[3], envelopes[4]].allSatisfy {
        $0.mediaGeneration == retryMediaGeneration
      })
      guard case .didStop(reason: .failure) = envelopes[2].event else {
        Issue.record("Expected the failed attempt's trailing stop")
        return
      }
    }

    @Test
    func `A failed stop cannot consume the programmatic stop reason of its retry`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failedMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.retry-stop", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.stop()

      // The first stop still belongs to the failed attempt. Its reason and
      // attribution must move together, leaving the retry's programmatic stop
      // intact across the later will-start callback.
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(4, from: stream)
      #expect(envelopes[0].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[1].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[2].mediaGeneration == retryMediaGeneration)
      #expect(envelopes[3].mediaGeneration == retryMediaGeneration)
      guard case .didStop(reason: .failure) = envelopes[1].event else {
        Issue.record("Expected the failed attempt's trailing stop")
        return
      }
      guard case .didStop(reason: .unknown) = envelopes[3].event else {
        Issue.record("Expected the retry's programmatic stop reason")
        return
      }
    }

    @Test
    func `A second failed attempt retires an earlier failure without a trailing stop`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let firstMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.consecutive-failures", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      try player.load(Media(url: TestMedia.silenceURL))
      let secondMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(3, from: stream)
      #expect(envelopes[0].mediaGeneration == firstMediaGeneration)
      #expect(envelopes[1].mediaGeneration == secondMediaGeneration)
      #expect(envelopes[2].mediaGeneration == secondMediaGeneration)
      guard case .didStop(reason: .failure) = envelopes[2].event else {
        Issue.record("Expected the second failed attempt's trailing stop")
        return
      }
    }

    @Test
    func `A retry accepted during an undiscriminated stop keeps its media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      try player.load(Media(url: TestMedia.twosecURL))
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)

      let envelopes = await collect(5, from: stream)
      #expect(envelopes[4].mediaGeneration == retryMediaGeneration)
    }

    @Test
    func `A failed queued retry is not promoted after the older stop`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let originalMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.queued-failure", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)

      // The media can move again before AVKit reports that the queued retry
      // failed. That failure still belongs to the accepted retry. Once the
      // older lifecycle stops, the failed retry must not be promoted as a
      // phantom awaiting start; a later willStart is an automatic start for
      // the signal-time media.
      try player.load(Media(url: TestMedia.twosecURL))
      let automaticMediaGeneration = player.generation
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)

      let envelopes = await collect(6, from: stream)
      #expect(envelopes[3].mediaGeneration == retryMediaGeneration)
      #expect(envelopes[4].mediaGeneration == originalMediaGeneration)
      #expect(envelopes[5].mediaGeneration == automaticMediaGeneration)
      guard case .didStop(reason: .userClosed) = envelopes[4].event else {
        Issue.record("Expected the older lifecycle's undiscriminated stop")
        return
      }
    }

    @Test
    func `A failure that loses stop precedence preserves the old lifecycle and queues its retry`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let originalMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.restore-precedence", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureController(
        avController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { _ in }
      )
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      try player.load(Media(url: TestMedia.twosecURL))
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)

      let envelopes = await collect(5, from: stream)
      #expect(envelopes.prefix(4).allSatisfy {
        $0.mediaGeneration == originalMediaGeneration
      })
      #expect(envelopes[4].mediaGeneration == retryMediaGeneration)
      guard case .didStop(reason: .restoreRequested) = envelopes[3].event else {
        Issue.record("Expected restore to retain stop precedence")
        return
      }
    }

    @Test
    func `restore then stop reports restoreRequested, plain stop reports userClosed`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let restored = Mutex(false)

      // Cycle 1: the user taps the restore affordance. With no
      // onRestoreUserInterface hook the completion runs immediately.
      controller.pictureInPictureController(
        avController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { ok in
          restored.withLock { $0 = ok }
        }
      )
      #expect(restored.withLock { $0 })
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      // Cycle 2: a stop with no discriminating signal is the close (X)
      // button on the sample-buffer path. Also proves didStop cleared
      // the pending reason from cycle 1.
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(4, from: stream)
      guard case .willStop(reason: .restoreRequested) = events[0] else {
        Issue.record("Expected .willStop(.restoreRequested), got \(events[0])")
        return
      }
      guard case .didStop(reason: .restoreRequested) = events[1] else {
        Issue.record("Expected .didStop(.restoreRequested), got \(events[1])")
        return
      }
      guard case .willStop(reason: .userClosed) = events[2] else {
        Issue.record("Expected .willStop(.userClosed), got \(events[2])")
        return
      }
      guard case .didStop(reason: .userClosed) = events[3] else {
        Issue.record("Expected .didStop(.userClosed), got \(events[3])")
        return
      }
    }

    @Test
    func `stop after natural end of media reports mediaEnded`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents

      // `.endReached` with inactive playback intent marks a natural end.
      #expect(player.isPlaybackRequestedActive == false)
      player._handleEventForTesting(.endReached)
      #expect(player.didReachEnd)

      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(2, from: stream)
      guard case .willStop(reason: .mediaEnded) = events[0] else {
        Issue.record("Expected .willStop(.mediaEnded), got \(events[0])")
        return
      }
      guard case .didStop(reason: .mediaEnded) = events[1] else {
        Issue.record("Expected .didStop(.mediaEnded), got \(events[1])")
        return
      }
    }

    /// The first discriminating signal wins: a recorded failure
    /// outranks the media-end fallback, and a recorded restore request
    /// is never overwritten by a later failure signal.
    @Test
    func `pending stop reason outranks media end and is not overwritten`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let failure = NSError(domain: "swiftvlc.test.pip", code: 7)

      // didReachEnd is set, but the failure signal takes precedence.
      player._handleEventForTesting(.endReached)
      #expect(player.didReachEnd)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      // Restore first, then a failure signal: restore sticks.
      controller.pictureInPictureController(
        avController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { _ in }
      )
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(4, from: stream)
      guard case .didStop(reason: .failure) = events[1] else {
        Issue.record("Expected .didStop(.failure), got \(events[1])")
        return
      }
      guard case .didStop(reason: .restoreRequested) = events[3] else {
        Issue.record("Expected .didStop(.restoreRequested), got \(events[3])")
        return
      }
    }

    @Test
    func `programmatic stop reports unknown`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents

      controller._setStateForTesting(isActive: true)
      controller.stop()
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(2, from: stream)
      guard case .willStop(reason: .unknown) = events[0] else {
        Issue.record("Expected .willStop(.unknown), got \(events[0])")
        return
      }
      guard case .didStop(reason: .unknown) = events[1] else {
        Issue.record("Expected .didStop(.unknown), got \(events[1])")
        return
      }
    }

    /// A fresh start clears any stale pending reason from a previous
    /// failed attempt, so the next stop resolves independently.
    @Test
    func `willStart clears a stale pending stop reason`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEvents
      let failure = NSError(domain: "swiftvlc.test.pip", code: 1)

      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let events = await collect(4, from: stream)
      guard case .didStop(reason: .userClosed) = events[3] else {
        Issue.record("Expected .didStop(.userClosed), got \(events[3])")
        return
      }
    }

    @Test
    func `native backend active flips synthesize didStart and didStop unknown`() async {
      let player = Player(instance: TestInstance.shared)
      #if os(iOS)
      let backend = IOSNativePiPBackend()
      #else
      let backend = MacNativePiPBackend()
      #endif
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEvents

      controller.handleNativePictureInPictureActiveChanged(true)
      // A redundant flip must not double-emit.
      controller.handleNativePictureInPictureActiveChanged(true)
      controller.handleNativePictureInPictureActiveChanged(false)
      controller.handleNativePictureInPictureActiveChanged(false)

      let events = await collect(2, from: stream)
      guard case .didStart = events[0] else {
        Issue.record("Expected .didStart, got \(events[0])")
        return
      }
      guard case .didStop(reason: .unknown) = events[1] else {
        Issue.record("Expected .didStop(.unknown), got \(events[1])")
        return
      }
    }

    @Test
    func `Native backend events carry one nonzero controller generation`() async {
      let player = Player(instance: TestInstance.shared)
      #if os(iOS)
      let backend = IOSNativePiPBackend()
      #else
      let backend = MacNativePiPBackend()
      #endif
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes

      controller.handleNativePictureInPictureActiveChanged(true)
      controller.handleNativePictureInPictureActiveChanged(false)

      let events = await collect(2, from: stream)
      #expect(events.map(\.controllerGeneration) == [1, 1])
      #expect(events.allSatisfy { $0.mediaGeneration == player.generation })
    }

    @Test
    func `A later inactive iOS native start supersedes an unobservable failed attempt`() async throws {
      #if os(iOS)
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = IOSNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.handleNativePictureInPictureActiveChanged(true)

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == retryMediaGeneration)
      #endif
    }

    #if os(macOS)
    @Test
    func `A macOS active update queued to its owner preserves the accepted media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let acceptedGeneration = player.generation

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      backend.setActive(true)
      try player.load(Media(url: TestMedia.silenceURL))
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == acceptedGeneration)
    }

    @Test
    func `A queued macOS transition follows a same-player owner handoff`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let original = PiPController(player: player, nativeBackend: backend)
      let originalStream = original.pipEventEnvelopes

      backend.setActive(true)
      _ = try #require(await collect(1, from: originalStream).first)
      let lifecycleMediaGeneration = try #require(backend.activeMediaGeneration)

      // `setActive(false)` defers observer delivery. Reconstruct the
      // controller synchronously before that task runs; the transition must
      // follow the adopted same-player backend instead of the captured owner.
      backend.setActive(false)
      let successor = PiPController(player: player, nativeBackend: backend)
      let successorStream = successor.pipEventEnvelopes
      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(successor.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      backend.setActive(true)

      let envelopes = await collect(2, from: successorStream)
      #expect(backend.owner === successor)
      #expect(envelopes[0].mediaGeneration == lifecycleMediaGeneration)
      #expect(envelopes[1].mediaGeneration == retryMediaGeneration)
      guard case .didStop(reason: .unknown) = envelopes[0].event else {
        Issue.record("Expected the queued stop on the successor owner")
        return
      }
      guard case .didStart = envelopes[1].event else {
        Issue.record("Expected the successor's accepted retry to remain current")
        return
      }
      withExtendedLifetime(original) {}
    }
    #endif

    @Test
    func `Callback snapshot publishes media generation before a callback hop`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let signalGeneration = controller.callbackSnapshot.withLock {
        $0.playbackGeneration
      }

      try player.load(Media(url: TestMedia.silenceURL))
      let successorGeneration = controller.callbackSnapshot.withLock {
        $0.playbackGeneration
      }

      #expect(signalGeneration != nil)
      #expect(signalGeneration != successorGeneration)
      #expect(successorGeneration == player.generation)
    }

    @Test
    func `Adopting active native PiP retains its original media generation`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      #if os(iOS)
      let backend = IOSNativePiPBackend()
      #else
      let backend = MacNativePiPBackend()
      #endif
      backend.attach(to: player)
      backend.setActive(true)
      let lifecycleMediaGeneration = player.generation
      try player.load(Media(url: TestMedia.silenceURL))
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes

      #expect(controller.isActive)
      backend.setActive(false)

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == lifecycleMediaGeneration)
      guard case .didStop = envelope.event else {
        Issue.record("Expected .didStop, got \(envelope.event)")
        return
      }
    }

    @Test
    func `An active native backend persists accepted media across owner reconstruction`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      #if os(iOS)
      let backend = IOSNativePiPBackend()
      #else
      let backend = MacNativePiPBackend()
      #endif
      backend.attach(to: player)
      let original = PiPController(player: player, nativeBackend: backend)
      let acceptedGeneration = player.generation
      #if os(iOS)
      let windowController = NativePiPWindowControllerProbe()
      backend.handlePictureInPictureReady(windowController)
      #expect(original.noteAcceptedPiPStartRequest(backend.start()) == .accepted)
      #else
      #expect(original.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      #endif

      try player.load(Media(url: TestMedia.silenceURL))
      #if os(iOS)
      backend.setActive(true, mediaGeneration: player.generation)
      #else
      backend.setActive(true)
      #endif

      let successor = PiPController(player: player, nativeBackend: backend)
      let stream = successor.pipEventEnvelopes
      backend.setActive(false)

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == acceptedGeneration)
      withExtendedLifetime(original) {}
    }

    @Test
    func `An automatic native start retires an accepted request from a replaced controller`() async throws {
      #if os(iOS)
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = IOSNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes

      backend.handlePictureInPictureReady(NativePiPWindowControllerProbe())
      #expect(controller.noteAcceptedPiPStartRequest(backend.start()) == .accepted)

      try player.load(Media(url: TestMedia.silenceURL))
      let automaticMediaGeneration = player.generation
      // libVLC rebuilt its native window controller for the successor media.
      // An active signal from this controller cannot be the result of the
      // explicit request sent to the retired controller.
      backend.handlePictureInPictureReady(NativePiPWindowControllerProbe())
      backend.setActive(true, mediaGeneration: automaticMediaGeneration)

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == automaticMediaGeneration)
      #endif
    }

    @Test
    func `pipEvents stream finishes when the controller deinits`() async throws {
      let player = Player(instance: TestInstance.shared)
      var controller: PiPController? = PiPController(player: player)
      let stream = try #require(controller?.pipEvents)

      controller = nil

      // The broadcaster terminates in deinit; the stream must finish
      // rather than suspend forever.
      for await event in stream {
        Issue.record("Expected no events, got \(event)")
      }
    }

    @Test
    func `pipEventEnvelopes stream finishes when the controller deinits`() async throws {
      let player = Player(instance: TestInstance.shared)
      var controller: PiPController? = PiPController(player: player)
      let stream = try #require(controller?.pipEventEnvelopes)

      controller = nil

      for await event in stream {
        Issue.record("Expected no envelopes, got \(event)")
      }
    }

    @Test
    func `multiple subscribers each receive every event`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let first = controller.pipEvents
      let second = controller.pipEvents

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      let firstEvents = await collect(2, from: first)
      let secondEvents = await collect(2, from: second)
      #expect(firstEvents.count == 2)
      #expect(secondEvents.count == 2)
      guard case .willStart = firstEvents[0], case .willStart = secondEvents[0] else {
        Issue.record("Both subscribers should see .willStart first")
        return
      }
    }

    @Test
    func `multiple envelope subscribers receive identical attribution`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let first = controller.pipEventEnvelopes
      let second = controller.pipEventEnvelopes

      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      let a = await collect(2, from: first)
      let b = await collect(2, from: second)
      #expect(a.map(\.mediaGeneration) == b.map(\.mediaGeneration))
      #expect(a.map(\.controllerGeneration) == b.map(\.controllerGeneration))
    }
  }
}

#if os(iOS)
private final class NativePiPWindowControllerProbe: NSObject {
  @objc func startPictureInPicture() {}
}
#endif
#endif
