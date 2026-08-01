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
  }
}
#endif
