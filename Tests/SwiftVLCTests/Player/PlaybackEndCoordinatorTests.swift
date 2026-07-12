@testable import SwiftVLC
import Testing

/// Decision table of ``PlaybackEndCoordinator``: a `stopped` synthesizes
/// `.endReached` only when no cause is pending; a library stop and an
/// error are one-shots consumed by the `stopped` that accounts for them,
/// while list-player suppression is a level that only `setSuppressed`
/// changes. Pure state-machine tests — no libVLC instance, no playback.
extension Logic {
  struct PlaybackEndCoordinatorTests {
    @Test
    func `Stopped with no recorded cause synthesizes an end`() {
      let coordinator = PlaybackEndCoordinator()
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Library stop suppresses one stopped and is consumed by it`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.markLibraryStop()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Error suppresses one stopped and is consumed by it`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.markError()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Library stop and error together are both consumed by one stopped`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.markLibraryStop()
      coordinator.markError()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Repeated marks of the same cause still cost a single stopped`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.markLibraryStop()
      coordinator.markLibraryStop()
      coordinator.markError()
      coordinator.markError()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Suppression is a level, not a one-shot`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.setSuppressed(true)
      for _ in 0..<3 {
        #expect(
          !coordinator.consumeStoppedShouldSynthesizeEnd(),
          "stopped synthesized while a list player is attached"
        )
      }
      coordinator.setSuppressed(false)
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    @Test
    func `Suppressed stopped still consumes the one-shot causes`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.setSuppressed(true)
      coordinator.markLibraryStop()
      coordinator.markError()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd())
      coordinator.setSuppressed(false)
      #expect(
        coordinator.consumeStoppedShouldSynthesizeEnd(),
        "one-shots survived a suppressed stopped and swallowed a later natural end"
      )
    }

    @Test
    func `Handle-replacement clear drops the one-shots`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.markLibraryStop()
      coordinator.markError()
      coordinator.clearForHandleReplacement()
      #expect(
        coordinator.consumeStoppedShouldSynthesizeEnd(),
        "a cleared one-shot still suppressed the next natural end"
      )
    }

    @Test
    func `Handle-replacement clear leaves suppression in place`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.setSuppressed(true)
      coordinator.markLibraryStop()
      coordinator.clearForHandleReplacement()
      #expect(
        !coordinator.consumeStoppedShouldSynthesizeEnd(),
        "handle replacement lifted list-player suppression"
      )
      coordinator.setSuppressed(false)
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd())
    }

    /// Every combination of the three causes: synthesis only with none
    /// pending, the one-shots always consumed, suppression always kept.
    @Test(
      arguments: [
        (false, false, false),
        (true, false, false),
        (false, true, false),
        (false, false, true),
        (true, true, false),
        (true, false, true),
        (false, true, true),
        (true, true, true)
      ] as [(Bool, Bool, Bool)]
    )
    func `Full decision table`(libraryStop: Bool, error: Bool, suppressed: Bool) {
      let coordinator = PlaybackEndCoordinator()
      if libraryStop {
        coordinator.markLibraryStop()
      }
      if error {
        coordinator.markError()
      }
      coordinator.setSuppressed(suppressed)

      let expected = !libraryStop && !error && !suppressed
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd() == expected)

      // Second stopped: one-shots are gone; only suppression can remain.
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd() == !suppressed)
    }
  }
}
