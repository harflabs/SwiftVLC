@testable import SwiftVLC
import CLibVLC
import Testing

extension Logic {
  @Suite(.tags(.async))
  struct SubtitleTextCoverageTests {
    @Test
    func `Termination racing registration rejects the attachment`() async {
      let lifetime = makeLifetime(22)
      let bridge = SubtitleTextBridge()

      #expect(
        !bridge.attach(to: lifetime) { _, _ in
          bridge.terminate()
          return true
        }
      )

      var values = bridge.subscribe().makeAsyncIterator()
      #expect(await values.next() == nil)
      lifetime.initialOwnerDidRelease()
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerTextSubtitleCoverageTests {
    @Test
    func `Public API matches the released artifact text capture capability`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())

      if SubtitleTextNativeOperations.live.isAvailable() {
        _ = try player.textSubtitleStream()
        #expect(player.isTextSubtitleCaptureEnabled)
      } else {
        do {
          _ = try player.textSubtitleStream()
          Issue.record("Expected text capture to reject an artifact without the native extension")
        } catch {
          #expect(
            error
              == .operationFailed(
                "Enable text subtitle capture (custom libVLC build required)"
              )
          )
        }
        #expect(!player.isTextSubtitleCaptureEnabled)
      }
    }

    @Test
    func `Player reattach rejects an unavailable extension`() throws {
      let harness = SubtitleTextCallbackHarness()
      let player = Player(instance: TestInstance.makeAudioOnly())
      _ = try player.textSubtitleStream(
        using: makeCoverageNativeOperations(harness: harness)
      )
      player.subtitleTextNativeOperations = makeCoverageNativeOperations(
        harness: harness,
        isAvailable: false
      )
      let successorLifetime = makeLifetime(23)
      defer { successorLifetime.initialOwnerDidRelease() }

      do {
        try player.reattachTextSubtitleCaptureIfEnabled(to: successorLifetime)
        Issue.record("Expected unavailable capture reattachment to fail")
      } catch {
        #expect(error == .operationFailed("Reattach text subtitle capture"))
      }
      #expect(harness.availabilityProbeCount == 2)
      #expect(harness.registrationAttempts == 1)
    }
  }
}

@MainActor
private func makeCoverageNativeOperations(
  harness: SubtitleTextCallbackHarness,
  isAvailable: Bool = true
) -> SubtitleTextNativeOperations {
  SubtitleTextNativeOperations(
    isAvailable: { harness.probeAvailability(isAvailable) },
    register: { player, callback, opaque in
      harness.register(player, callback, opaque)
    }
  )
}
