@testable import SwiftVLC
import Observation
import Synchronization
import Testing

/// Covers `Player.handleEvent` branches that production libVLC rarely
/// triggers in a headless test environment (encountered-error state
/// transitions, chapter / title / device / program change fan-out,
/// buffering-progress lifecycle guards).
///
/// These tests call `_handleEventForTesting` directly, bypassing the
/// real event bridge, so they're deterministic and don't depend on
/// playback reaching `.playing`. That lets us pin the observable-
/// property side effects on the event → mutation mapping without
/// waiting for a decoder we can't guarantee exists.
@Suite(.tags(.integration, .mainActor))
@MainActor
struct PlayerEventHandlerTests {
  // MARK: - encounteredError

  /// `encounteredError` must force the state to `.error` and invalidate
  /// both `isPlaying` and `isActive`.
  @Test
  func `encounteredError transitions to error state`() {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .playing)

    player._handleEventForTesting(.encounteredError)

    #expect(player.state == .error)
    #expect(player.isPlaying == false)
    #expect(player.isActive == false)
  }

  // MARK: - bufferingProgress

  /// Buffer fill must be published even when the player is `.paused`,
  /// so paused-but-preloading UIs can show progress.
  @Test
  func `bufferingProgress updates bufferFill from paused state`() {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .paused)

    player._handleEventForTesting(.bufferingProgress(0.42))

    #expect(player.bufferFill == 0.42)
    #expect(player.state == .paused, "State must not downgrade to .buffering after .paused")
  }

  /// From `.idle`, the first buffering event must lift state into
  /// `.buffering` so the UI can show the spinner.
  @Test
  func `bufferingProgress from idle promotes state to buffering`() {
    let player = Player(instance: TestInstance.shared)

    player._handleEventForTesting(.bufferingProgress(0.1))

    #expect(player.state == .buffering)
    #expect(player.bufferFill == 0.1)
  }

  /// A second buffering event after the state is already `.buffering`
  /// must NOT re-transition the state (would create spurious observer
  /// invalidations) — only update `bufferFill`.
  @Test
  func `bufferingProgress while already buffering only updates fill`() {
    let player = Player(instance: TestInstance.shared)
    player._handleEventForTesting(.bufferingProgress(0.1))
    #expect(player.state == .buffering)

    let firedCount = Mutex(0)
    withObservationTracking {
      _ = player.state
    } onChange: {
      firedCount.withLock { $0 += 1 }
    }

    player._handleEventForTesting(.bufferingProgress(0.5))

    #expect(player.bufferFill == 0.5)
    #expect(firedCount.withLock { $0 } == 0, "State must not fire an observer change on fill-only update")
  }

  /// From `.playing`, buffering events only update `bufferFill` — the
  /// state machine is otherwise driven by `.stateChanged`.
  @Test
  func `bufferingProgress while playing does not downgrade state`() {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .playing)

    player._handleEventForTesting(.bufferingProgress(0.9))

    #expect(player.state == .playing)
    #expect(player.bufferFill == 0.9)
  }

  // MARK: - Time / position updates

  @Test
  func `timeChanged updates currentTime`() {
    let player = Player(instance: TestInstance.shared)

    player._handleEventForTesting(.timeChanged(.seconds(42)))

    #expect(player.currentTime == .seconds(42))
  }

  @Test
  func `lengthChanged updates duration`() {
    let player = Player(instance: TestInstance.shared)

    player._handleEventForTesting(.lengthChanged(.seconds(180)))

    #expect(player.duration == .seconds(180))
  }

  @Test
  func `seekableChanged and pausableChanged update flags`() {
    let player = Player(instance: TestInstance.shared)

    player._handleEventForTesting(.seekableChanged(true))
    player._handleEventForTesting(.pausableChanged(true))

    #expect(player.isSeekable == true)
    #expect(player.isPausable == true)
  }

  // MARK: - Stopped state cleanup

  /// A `.stopped` state-change must reset time, fill, and position to
  /// zero so the next `play()` starts from a clean slate.
  @Test
  func `stateChanged to stopped resets derived state`() {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(
      state: .playing,
      currentTime: .seconds(30),
      position: 0.5
    )

    player._handleEventForTesting(.stateChanged(.stopped))

    #expect(player.state == .stopped)
    #expect(player.currentTime == .zero)
    #expect(player.bufferFill == 0)
  }

  // MARK: - Observation invalidation for external state changes

  /// `.volumeChanged` must invalidate the `volume` observer so SwiftUI
  /// picks up a hardware-button-driven volume change. The actual
  /// value is read from libVLC in the computed getter.
  @Test
  func `volumeChanged invalidates the volume observer`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.volume
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.volumeChanged(0.6))

    #expect(fired.withLock { $0 })
  }

  @Test
  func `muted event invalidates the isMuted observer`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.isMuted
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.muted)

    #expect(fired.withLock { $0 })
  }

  @Test
  func `unmuted event invalidates the isMuted observer`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.isMuted
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.unmuted)

    #expect(fired.withLock { $0 })
  }

  @Test
  func `chapterChanged invalidates currentChapter`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.currentChapter
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.chapterChanged(3))

    #expect(fired.withLock { $0 })
  }

  @Test
  func `titleSelectionChanged invalidates currentTitle`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.currentTitle
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.titleSelectionChanged(2))

    #expect(fired.withLock { $0 })
  }

  @Test
  func `audioDeviceChanged invalidates currentAudioDevice`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.currentAudioDevice
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.audioDeviceChanged("core-audio"))

    #expect(fired.withLock { $0 })
  }

  /// Program-related events fan out to `programs`, `selectedProgram`,
  /// and `isProgramScrambled` — any of those observers must fire.
  @Test
  func `program events invalidate program observers`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.programs
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.programAdded(1))

    #expect(fired.withLock { $0 })
  }

  @Test
  func `programSelected event invalidates selectedProgram observer`() {
    let player = Player(instance: TestInstance.shared)
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.selectedProgram
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.programSelected(unselectedId: 1, selectedId: 2))

    #expect(fired.withLock { $0 })
  }

  // MARK: - No-op events

  /// Events that don't map to observable state must not crash and
  /// must not mutate any observable properties. A single stateful
  /// snapshot around the event call catches regressions.
  @Test
  func `no-op events do not mutate observable state`() {
    let player = Player(instance: TestInstance.shared)
    player._setStateForTesting(state: .playing, currentTime: .seconds(5))

    let beforeState = player.state
    let beforeTime = player.currentTime

    player._handleEventForTesting(.corked)
    player._handleEventForTesting(.uncorked)
    player._handleEventForTesting(.voutChanged(1))
    player._handleEventForTesting(.recordingChanged(isRecording: true, filePath: "/tmp/r.ts"))
    player._handleEventForTesting(.titleListChanged)
    player._handleEventForTesting(.snapshotTaken("/tmp/s.png"))
    player._handleEventForTesting(.mediaStopping)

    #expect(player.state == beforeState)
    #expect(player.currentTime == beforeTime)
  }
}
