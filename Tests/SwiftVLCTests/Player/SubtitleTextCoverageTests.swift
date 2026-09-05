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
    func `Public API reports the released artifact lacks text capture`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let callback: swiftvlc_subtitle_text_snapshot_cb = { _, _, _ in }
      let opaque = Unmanaged.passUnretained(player).toOpaque()

      #expect(
        !SubtitleTextNativeOperations.live.register(
          player.pointer,
          callback,
          opaque
        )
      )
      do {
        _ = try player.textSubtitleStream()
        Issue.record("Expected the released libVLC artifact to lack text capture")
      } catch {
        #expect(
          error
            == .operationFailed(
              "Enable text subtitle capture (custom libVLC build required)"
            )
        )
      }

      let harness = SubtitleTextCallbackHarness()
      _ = try player.textSubtitleStream(using: makeCoverageNativeOperations(harness: harness))
      _ = try player.textSubtitleStream()
      #expect(harness.availabilityProbeCount == 1)
      #expect(harness.registrationAttempts == 1)
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
