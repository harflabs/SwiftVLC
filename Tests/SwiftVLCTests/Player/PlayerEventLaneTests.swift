@testable import SwiftVLC
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
  }
}
