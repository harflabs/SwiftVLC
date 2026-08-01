#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVKit
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPEventOverlapTests {
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
    func `A queued retry failure does not steal the older lifecycle's stop`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let originalMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.queued-retry-failure", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )

      // The older, already-started lifecycle still owns the first terminal
      // stop. A later optional stop belongs to the failed retry.
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(6, from: stream)
      #expect(envelopes[3].mediaGeneration == retryMediaGeneration)
      #expect(envelopes[4].mediaGeneration == originalMediaGeneration)
      #expect(envelopes[5].mediaGeneration == retryMediaGeneration)
      guard case .didStop(reason: .userClosed) = envelopes[4].event else {
        Issue.record("Expected the older lifecycle's undiscriminated stop")
        return
      }
      guard case .didStop(reason: .failure) = envelopes[5].event else {
        Issue.record("Expected the queued retry's failure stop")
        return
      }
    }

    @Test
    func `A stopped accepted start retires when its failure arrives`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failedMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.stopped-start-failure", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.stop()
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      #expect(controller.resolveStopReason() == .unknown)

      // AVKit may omit didStop after a start failure. A new successful start
      // must therefore replace the retired attempt instead of queuing forever
      // behind its old awaiting-start slot.
      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)

      let envelopes = await collect(3, from: stream)
      #expect(envelopes[0].mediaGeneration == failedMediaGeneration)
      #expect(envelopes.dropFirst().allSatisfy {
        $0.mediaGeneration == retryMediaGeneration
      })
    }

    @Test
    func `A failed willStop survives a newer didStart until didStop`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failedMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.failed-will-stop", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(6, from: stream)
      #expect(envelopes[1].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[4].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[5].mediaGeneration == retryMediaGeneration)
      guard case .didStop(reason: .failure) = envelopes[4].event else {
        Issue.record("Expected the promised failed-lifecycle stop")
        return
      }
    }

    @Test
    func `An active retry owns its willStop while a failed stop is delayed`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failedMediaGeneration = player.generation
      let failure = NSError(domain: "swiftvlc.test.pip.delayed-failed-stop", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.stop()
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(7, from: stream)
      #expect(envelopes[1].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[4].mediaGeneration == retryMediaGeneration)
      #expect(envelopes[5].mediaGeneration == failedMediaGeneration)
      #expect(envelopes[6].mediaGeneration == retryMediaGeneration)
      guard case .willStop(reason: .unknown) = envelopes[4].event else {
        Issue.record("Expected the active retry's programmatic willStop")
        return
      }
      guard case .didStop(reason: .failure) = envelopes[5].event else {
        Issue.record("Expected the delayed failed stop first")
        return
      }
      guard case .didStop(reason: .unknown) = envelopes[6].event else {
        Issue.record("Expected the active retry's stop second")
        return
      }
    }

    @Test
    func `Promised failed stop remains ordered ahead of a failed retry`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let originalMediaGeneration = player.generation
      let originalFailure = NSError(domain: "swiftvlc.test.pip.promised-failure", code: 1)
      let retryFailure = NSError(domain: "swiftvlc.test.pip.retry-failure", code: 2)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: originalFailure
      )
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: retryFailure
      )

      controller.pictureInPictureControllerDidStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(5, from: stream)
      #expect(envelopes[1].mediaGeneration == originalMediaGeneration)
      #expect(envelopes[2].mediaGeneration == retryMediaGeneration)
      #expect(envelopes[3].mediaGeneration == originalMediaGeneration)
      #expect(envelopes[4].mediaGeneration == retryMediaGeneration)
      guard case .didStop(reason: .failure) = envelopes[3].event else {
        Issue.record("Expected the promised original failure stop first")
        return
      }
      guard case .didStop(reason: .failure) = envelopes[4].event else {
        Issue.record("Expected the failed retry stop second")
        return
      }
    }

    @Test
    func `A cleanup stop after failure cannot poison a successful retry`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      let stream = controller.pipEventEnvelopes
      let failure = NSError(domain: "swiftvlc.test.pip.failed-cleanup-stop", code: 1)

      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      controller.pictureInPictureController(
        avController,
        failedToStartPictureInPictureWithError: failure
      )
      controller.stop()
      #expect(controller.pendingStopReason == .unknown)

      try player.load(Media(url: TestMedia.silenceURL))
      let retryMediaGeneration = player.generation
      #expect(controller.noteAcceptedPiPStartRequest(.accepted) == .accepted)
      #expect(controller.pendingStopReason == nil)
      controller.pictureInPictureControllerWillStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStartPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let envelopes = await collect(4, from: stream)
      #expect(envelopes.dropFirst().allSatisfy {
        $0.mediaGeneration == retryMediaGeneration
      })
      guard case .didStop(reason: .userClosed) = envelopes[3].event else {
        Issue.record("Expected the retry's independent user-close reason")
        return
      }
    }

    #if os(iOS)
    @Test
    func `An ownerless native active signal retains its accepted media`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      _ = try #require(backend.callbackGenerations.reserveReadyCallback(for: attachment))
      var original: PiPController? = PiPController(player: player, nativeBackend: backend)
      weak var releasedOriginal = original
      let acceptedMediaGeneration = player.generation
      #expect(backend.callbackGenerations.recordAcceptedStart(
        mediaGeneration: acceptedMediaGeneration
      ))

      original = nil
      await Task.yield()
      #expect(releasedOriginal == nil)
      #expect(backend.owner == nil)

      try player.load(Media(url: TestMedia.silenceURL))
      backend.setActive(true, mediaGeneration: player.generation)
      let successor = PiPController(player: player, nativeBackend: backend)
      let stream = successor.pipEventEnvelopes
      backend.setActive(false)

      let envelope = try #require(await collect(1, from: stream).first)
      #expect(envelope.mediaGeneration == acceptedMediaGeneration)
      withExtendedLifetime(successor) {}
    }
    #endif
  }
}
#endif
