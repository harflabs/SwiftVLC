@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

@Suite(.tags(.logic))
struct PlayerEventLaneClassificationTests {
  @Test
  func `Continuous events are on the timing lane`() {
    #expect(PlayerEvent.timeChanged(.seconds(1)).lane == .timing)
    #expect(PlayerEvent.positionChanged(0.5).lane == .timing)
    #expect(PlayerEvent.bufferingProgress(0.25).lane == .timing)
    #expect(PlayerEvent.voutChanged(1).lane == .timing)
  }

  /// The events whose loss leaves a consumer permanently wrong. Terminal
  /// outcomes matter most: nothing re-states an `.endReached`.
  @Test
  func `One-shot events are on the control lane`() {
    #expect(PlayerEvent.stateChanged(.playing).lane == .control)
    #expect(PlayerEvent.mediaChanged.lane == .control)
    #expect(PlayerEvent.mediaStopping.lane == .control)
    #expect(PlayerEvent.endReached.lane == .control)
    #expect(PlayerEvent.encounteredError.lane == .control)
    #expect(PlayerEvent.lengthChanged(.seconds(9)).lane == .control)
    #expect(PlayerEvent.seekableChanged(true).lane == .control)
    #expect(PlayerEvent.pausableChanged(true).lane == .control)
    #expect(PlayerEvent.tracksChanged.lane == .control)
    #expect(PlayerEvent.programSelected(unselectedId: 1, selectedId: 2).lane == .control)
  }

  @Test
  func `Native generations are ordered opaque diagnostic values`() {
    let first = NativePlayerGeneration(1)
    let second = NativePlayerGeneration(2)
    #expect(first < second)
    #expect(first.description == "native generation 1")
  }
}

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PlayerEventLaneTests {
    /// The acceptance criterion this issue exists for: more than 64 timing
    /// events cannot hide a one-shot control event.
    ///
    /// The control event is broadcast *first*, so it sits on the oldest side
    /// of the backlog — precisely where a newest-wins buffer evicts. On the
    /// mixed `events` stream a burst this size drops it; on the control lane
    /// the burst never enters the buffer, so no burst size can reach it.
    @Test(.timeLimit(.minutes(1)))
    func `A timing burst cannot evict a control event`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let nativeHandleGeneration = bridge.currentNativeHandleGeneration
      let stream = player.controlEvents

      bridge._broadcastForTesting(.lengthChanged(.seconds(2)), nativeHandleGeneration: nativeHandleGeneration)
      for index in 0..<500 {
        bridge._broadcastForTesting(.timeChanged(.milliseconds(index)), nativeHandleGeneration: nativeHandleGeneration)
        bridge._broadcastForTesting(.positionChanged(Double(index) / 500), nativeHandleGeneration: nativeHandleGeneration)
      }
      // Bounds the drain: once this arrives, everything before it has been
      // delivered or dropped, so the assertions below are not racing.
      bridge._broadcastForTesting(.mediaChanged, nativeHandleGeneration: nativeHandleGeneration)

      var sawBuriedControlEvent = false
      var timingEventCount = 0
      drain: for await event in stream {
        switch event {
        case .lengthChanged(let duration) where duration == .seconds(2):
          sawBuriedControlEvent = true
        case .timeChanged, .positionChanged, .bufferingProgress, .voutChanged:
          timingEventCount += 1
        case .mediaChanged:
          break drain
        default:
          break
        }
      }

      #expect(sawBuriedControlEvent, "a 1000-event timing burst evicted a one-shot control event")
      #expect(timingEventCount == 0, "timing events leaked into the control lane")
    }

    /// The other half of the split: the timing lane must stay bounded under a
    /// firehose, and must not carry control events that a drop would lose.
    @Test(.timeLimit(.minutes(1)))
    func `The timing lane stays bounded and carries no control events`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let nativeHandleGeneration = bridge.currentNativeHandleGeneration
      let stream = player.timingEvents

      for index in 0..<500 {
        bridge._broadcastForTesting(.timeChanged(.milliseconds(index)), nativeHandleGeneration: nativeHandleGeneration)
      }
      // A control event cannot bound this drain — it is filtered out — so the
      // final timing sample is the sentinel instead.
      bridge._broadcastForTesting(.voutChanged(7), nativeHandleGeneration: nativeHandleGeneration)

      var delivered: [PlayerEvent] = []
      drain: for await event in stream {
        delivered.append(event)
        if case .voutChanged = event {
          break drain
        }
      }

      #expect(
        delivered.count <= Player.timingLaneBufferSize,
        "the timing lane buffered \(delivered.count) events, past its bound"
      )
      #expect(
        delivered.allSatisfy { $0.lane == .timing },
        "a control event leaked into the lossy timing lane"
      )
      // Newest-wins: the most recent sample survives the backlog.
      guard case .voutChanged(let count) = delivered.last else {
        Issue.record("the newest timing sample was dropped: \(String(describing: delivered.last))")
        return
      }
      #expect(count == 7)
    }

    /// A public consumer can keep a lossless control subscription alive across
    /// a native replacement and reject an event that was already queued from
    /// the predecessor. Pointer equality cannot prove this because an
    /// allocator may reuse the old address; the monotonic token can.
    @Test(.timeLimit(.minutes(1)))
    func `A queued predecessor event remains attributable after native replacement`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let bridge = player.eventBridge
      let stream = player.controlEventEnvelopes
      let predecessor = player.nativeEventGeneration

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()
      let successor = player.nativeEventGeneration
      #expect(successor > predecessor)

      // Simulate a value already queued from A becoming visible only after B
      // was installed. The following sentinel bounds the drain.
      bridge._broadcastForTesting(
        .stateChanged(.stopped),
        nativeHandleGeneration: predecessor.value
      )
      bridge._broadcastForTesting(
        .mediaChanged,
        nativeHandleGeneration: successor.value
      )

      var predecessorEnvelope: PlayerEventEnvelope?
      drain: for await envelope in stream {
        switch envelope.event {
        case .stateChanged(.stopped):
          predecessorEnvelope = envelope
        case .mediaChanged:
          break drain
        default:
          break
        }
      }

      let stale = try #require(predecessorEnvelope)
      #expect(stale.nativeGeneration == predecessor)
      #expect(stale.nativeGeneration != player.nativeEventGeneration)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A queued predecessor event remains attributable after same-handle media replacement`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let predecessor = player.generation
      let nativeGeneration = player.nativeEventGeneration
      let stream = player.controlEventEnvelopes

      try player.load(Media(url: TestMedia.silenceURL))
      let successor = player.generation
      #expect(successor > predecessor)
      #expect(player.nativeEventGeneration == nativeGeneration)

      player.eventBridge._broadcastForTesting(
        .stateChanged(.stopped),
        nativeHandleGeneration: nativeGeneration.value,
        playbackGeneration: predecessor.value
      )
      player.eventBridge._broadcastForTesting(
        .mediaChanged,
        nativeHandleGeneration: nativeGeneration.value,
        playbackGeneration: successor.value
      )

      var predecessorEnvelope: PlayerEventEnvelope?
      drain: for await envelope in stream {
        switch envelope.event {
        case .stateChanged(.stopped):
          predecessorEnvelope = envelope
        case .mediaChanged where predecessorEnvelope != nil:
          break drain
        case .mediaChanged:
          // `load` can deliver its native MediaChanged echo before the two
          // deterministic testing envelopes below reach this consumer. That
          // echo is unrelated to the ordering under test, so keep draining
          // until the injected predecessor has been observed.
          continue
        default:
          break
        }
      }

      let stale = try #require(predecessorEnvelope)
      #expect(stale.nativeGeneration == player.nativeEventGeneration)
      #expect(stale.playbackGeneration == predecessor)
      #expect(stale.playbackGeneration != player.generation)
    }

    @Test(.timeLimit(.minutes(1)))
    func `An external replay of the same media pointer starts a new generation`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let media = try Media(url: TestMedia.twosecURL)
      let first = PlaybackGeneration(
        player.eventBridge.synchronizePlaybackGeneration(1, media: media.pointer)
      )
      let stream = player.controlEventEnvelopes

      var changed = libvlc_event_t()
      changed.type = Int32(libvlc_MediaPlayerMediaChanged.rawValue)
      changed.u.media_player_media_changed.new_media = media.pointer
      player.eventBridge._emitNativeEventForTesting(changed)
      player.eventBridge._emitNativeEventForTesting(changed)

      var generations: [PlaybackGeneration] = []
      for await envelope in stream {
        guard case .mediaChanged = envelope.event else { continue }
        generations.append(envelope.playbackGeneration)
        if generations.count == 2 {
          break
        }
      }

      #expect(generations.first == first)
      #expect(generations.last.map { $0 > first } == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Envelope control lane excludes the timing firehose`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let generation = player.nativeEventGeneration
      let stream = player.controlEventEnvelopes

      bridge._broadcastForTesting(
        .lengthChanged(.seconds(2)),
        nativeHandleGeneration: generation.value
      )
      for index in 0..<500 {
        bridge._broadcastForTesting(
          .timeChanged(.milliseconds(index)),
          nativeHandleGeneration: generation.value
        )
      }
      bridge._broadcastForTesting(.mediaChanged, nativeHandleGeneration: generation.value)

      var events: [PlayerEvent] = []
      drain: for await envelope in stream {
        events.append(envelope.event)
        if case .mediaChanged = envelope.event {
          break drain
        }
        #expect(envelope.nativeGeneration == generation)
      }

      #expect(events.contains { event in
        if case .lengthChanged = event {
          true
        } else {
          false
        }
      })
      #expect(events.allSatisfy { $0.lane == .control })
    }

    @Test(.timeLimit(.minutes(1)))
    func `Default and filtered envelope streams preserve attribution`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let generation = player.nativeEventGeneration
      let defaultStream = player.eventEnvelopes
      let filteredStream = player.eventEnvelopes(policy: .unbounded) { envelope in
        envelope.event.lane == .control
      }

      bridge._broadcastForTesting(
        .timeChanged(.seconds(1)),
        nativeHandleGeneration: generation.value
      )
      bridge._broadcastForTesting(.mediaChanged, nativeHandleGeneration: generation.value)

      var defaultSawTiming = false
      defaultDrain: for await envelope in defaultStream {
        #expect(envelope.nativeGeneration == generation)
        switch envelope.event {
        case .timeChanged:
          defaultSawTiming = true
        case .mediaChanged:
          break defaultDrain
        default:
          break
        }
      }

      var firstFiltered: PlayerEventEnvelope?
      for await envelope in filteredStream {
        firstFiltered = envelope
        break
      }
      let filteredEnvelope = try #require(firstFiltered)
      #expect(filteredEnvelope.nativeGeneration == generation)
      #expect(filteredEnvelope.event.lane == .control)
      #expect(defaultSawTiming)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Envelope timing lane remains bounded`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let generation = player.nativeEventGeneration
      let stream = player.timingEventEnvelopes

      for index in 0..<500 {
        bridge._broadcastForTesting(
          .timeChanged(.milliseconds(index)),
          nativeHandleGeneration: generation.value
        )
      }
      bridge._broadcastForTesting(.voutChanged(7), nativeHandleGeneration: generation.value)

      var delivered: [PlayerEventEnvelope] = []
      drain: for await envelope in stream {
        delivered.append(envelope)
        if case .voutChanged = envelope.event {
          break drain
        }
      }

      #expect(delivered.count <= Player.timingLaneBufferSize)
      #expect(delivered.allSatisfy { $0.event.lane == .timing })
      #expect(delivered.allSatisfy { $0.nativeGeneration == generation })
    }
  }
}
