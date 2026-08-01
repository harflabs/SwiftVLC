#if os(iOS)
@testable import SwiftVLC
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPNativeSignalProvenanceTests {
    @Test
    func `active signal preserves accepted provenance across its actor hop`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let ready = try #require(
        backend.callbackGenerations.reserveReadyCallback(for: attachment)
      )
      let signaledMediaGeneration = player.generation

      #expect(
        backend.callbackGenerations.recordAcceptedStart(
          mediaGeneration: signaledMediaGeneration
        )
      )
      let acceptedAtSignal = try #require(
        backend.callbackGenerations.acceptedStart(at: ready)
      )

      // A successor request is accepted before the signal's queued main-actor
      // work runs. The already-delivered signal must retain the first request.
      try player.load(Media(url: TestMedia.silenceURL))
      #expect(
        backend.callbackGenerations.recordAcceptedStart(
          mediaGeneration: player.generation
        )
      )
      backend.setActiveFromNativeSignal(
        true,
        mediaGeneration: signaledMediaGeneration,
        acceptedStart: acceptedAtSignal
      )

      var iterator = stream.makeAsyncIterator()
      let envelope = try #require(await iterator.next())
      #expect(envelope.mediaGeneration == signaledMediaGeneration)
    }
  }
}
#endif
