@testable import SwiftVLC
import CLibVLC
import Testing

/// Decision table of ``PlaybackEndCoordinator``: only the engine's explicit
/// EOS reason synthesizes `.endReached`; an unattributed stop stays unknown.
extension Logic {
  struct PlaybackEndCoordinatorTests {
    @Test
    func `Stopped with no reason remains unattributed`() {
      let coordinator = PlaybackEndCoordinator()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `End-of-stream reason synthesizes exactly once`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos)
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `List-player suppression outranks end of stream`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.setSuppressed(true)
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos)
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())

      coordinator.setSuppressed(false)
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Handle replacement clears the outgoing reason`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos)
      coordinator.clearForHandleReplacement()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
    }
  }
}
