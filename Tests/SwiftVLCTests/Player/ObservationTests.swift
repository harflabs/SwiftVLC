@testable import SwiftVLC
import Observation
import Synchronization
import Testing

/// Verifies the library drives SwiftUI through the Observation framework
/// correctly for both stored and computed `@Observable` properties.
///
/// Computed properties like `volume`, `isMuted`, `currentChapter`, and
/// `currentTitle` read fresh values from libVLC in their getters. Their
/// `access(keyPath:)` call alone does not cause SwiftUI to re-render
/// when the underlying C state changes; the setter (and the event
/// consumer, for VLC-initiated changes) must call
/// `withMutation(keyPath:)`.
///
/// Observation's `willSet` / `didSet` run synchronously, so we don't
/// need to poll or sleep — the `onChange` closure has either fired or
/// conclusively not by the time the setter returns.
@Suite(
  .tags(.integration, .mainActor, .async),
  .timeLimit(.minutes(1)),
  .serialized
)
@MainActor
struct ObservationTests {
  // MARK: - Setter path

  // Setter → withMutation → didSet → onChange, all synchronous.

  @Test
  func `Volume setter invalidates volume observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.volume
    } onChange: {
      fired.withLock { $0 = true }
    }
    player.volume = 0.5
    #expect(fired.withLock { $0 })
  }

  @Test
  func `isMuted setter invalidates isMuted observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.isMuted
    } onChange: {
      fired.withLock { $0 = true }
    }
    player.isMuted = true
    #expect(fired.withLock { $0 })
  }

  @Test
  func `rate setter invalidates rate observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.rate
    } onChange: {
      fired.withLock { $0 = true }
    }
    player.rate = 1.25
    #expect(fired.withLock { $0 })
  }

  @Test
  func `audioDelay setter invalidates observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.audioDelay
    } onChange: {
      fired.withLock { $0 = true }
    }
    player.audioDelay = .milliseconds(100)
    #expect(fired.withLock { $0 })
  }

  @Test
  func `subtitleTextScale setter invalidates observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.subtitleTextScale
    } onChange: {
      fired.withLock { $0 = true }
    }
    player.subtitleTextScale = 1.5
    #expect(fired.withLock { $0 })
  }

  @Test
  func `role setter invalidates observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.role
    } onChange: {
      fired.withLock { $0 = true }
    }
    player.role = .music
    #expect(fired.withLock { $0 })
  }

  @Test
  func `state events invalidate isPlaying and isActive`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let isPlayingFired = Mutex(false)
    let isActiveFired = Mutex(false)

    withObservationTracking {
      _ = player.isPlaying
    } onChange: {
      isPlayingFired.withLock { $0 = true }
    }

    withObservationTracking {
      _ = player.isActive
    } onChange: {
      isActiveFired.withLock { $0 = true }
    }

    player._handleEventForTesting(.stateChanged(.playing))
    #expect(isPlayingFired.withLock { $0 })
    #expect(isActiveFired.withLock { $0 })
  }

  @Test
  func `tracksChanged invalidates selected track observations`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let audioFired = Mutex(false)
    let subtitleFired = Mutex(false)

    withObservationTracking {
      _ = player.selectedAudioTrack
    } onChange: {
      audioFired.withLock { $0 = true }
    }

    withObservationTracking {
      _ = player.selectedSubtitleTrack
    } onChange: {
      subtitleFired.withLock { $0 = true }
    }

    player._handleEventForTesting(.tracksChanged)
    #expect(audioFired.withLock { $0 })
    #expect(subtitleFired.withLock { $0 })
  }

  @Test
  func `audioDeviceChanged invalidates currentAudioDevice observation`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.currentAudioDevice
    } onChange: {
      fired.withLock { $0 = true }
    }

    player._handleEventForTesting(.audioDeviceChanged(nil))
    #expect(fired.withLock { $0 })
  }

  @Test
  func `program events invalidate program-derived observations`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let programsFired = Mutex(false)
    let selectedFired = Mutex(false)
    let scrambledFired = Mutex(false)

    withObservationTracking {
      _ = player.programs
    } onChange: {
      programsFired.withLock { $0 = true }
    }

    withObservationTracking {
      _ = player.selectedProgram
    } onChange: {
      selectedFired.withLock { $0 = true }
    }

    withObservationTracking {
      _ = player.isProgramScrambled
    } onChange: {
      scrambledFired.withLock { $0 = true }
    }

    player._handleEventForTesting(.programUpdated(1))
    #expect(programsFired.withLock { $0 })
    #expect(selectedFired.withLock { $0 })
    #expect(scrambledFired.withLock { $0 })
  }

  // MARK: - Stored properties (regression guards for macro wiring)

  /// `.state` is stored, so the macro wires observation up automatically
  /// via the generated setter. Use a real playback event (the first
  /// `.stateChanged` VLC emits) to cause the mutation, then wait for the
  /// observation callback itself because the raw VLC event stream can
  /// advance slightly ahead of the main-actor observer.
  @Test
  func `state mutation fires observation`() async throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    defer { player.stop() }
    let fired = Mutex(false)
    withObservationTracking {
      _ = player.state
    } onChange: {
      fired.withLock { $0 = true }
    }
    // Subscribe the `.playing` watcher BEFORE `play()` so the stream
    // can't miss the state-change event.
    let playing = subscribeAndAwait(.playing, on: player)
    try player.play(Media(url: TestMedia.twosecURL))
    try #require(await playing.value)
    #expect(try await poll(until: { fired.withLock { $0 } }))
  }

  // MARK: - Keypath isolation (guards against over-eager withMutation)

  /// Setting `volume` must NOT invalidate `isMuted` observers. Regression
  /// guard: if anyone ever changes `handleEvent` to fire
  /// `withMutation(keyPath: \.isMuted)` on `.volumeChanged`, SwiftUI
  /// would pointlessly re-render mute-dependent views on every volume
  /// change.
  @Test
  func `Volume change does not invalidate isMuted`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let muteFired = Mutex(false)
    withObservationTracking {
      _ = player.isMuted
    } onChange: {
      muteFired.withLock { $0 = true }
    }
    player.volume = 0.3
    #expect(!muteFired.withLock { $0 }, "isMuted observer fired for a volume-only mutation")
  }

  /// Setting `isMuted` must NOT invalidate `volume` observers.
  @Test
  func `Mute change does not invalidate volume`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let volumeFired = Mutex(false)
    withObservationTracking {
      _ = player.volume
    } onChange: {
      volumeFired.withLock { $0 = true }
    }
    player.isMuted = true
    #expect(!volumeFired.withLock { $0 }, "volume observer fired for a mute-only mutation")
  }

  /// A fresh `Player`'s `currentChapter` observation must not fire
  /// spuriously before any mutation is applied.
  @Test
  func `currentChapter observer does not fire spuriously on idle`() {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let chapterFired = Mutex(false)
    withObservationTracking {
      _ = player.currentChapter
    } onChange: {
      chapterFired.withLock { $0 = true }
    }
    #expect(!chapterFired.withLock { $0 })
  }
}
