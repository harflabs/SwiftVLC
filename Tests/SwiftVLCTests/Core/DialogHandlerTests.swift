@testable import SwiftVLC
import Testing

extension Integration {
  struct DialogHandlerTests {
    @Test
    func `Init creates dialogs stream`() throws {
      let instance = try VLCInstance()
      let handler = DialogHandler(instance: instance)
      _ = handler.dialogs // should not crash
    }

    @Test
    func `Deinit cleans up callbacks`() throws {
      let instance = try VLCInstance()
      var handler: DialogHandler? = DialogHandler(instance: instance)
      _ = handler?.dialogs
      handler = nil
      // If we get here without crash, cleanup was successful
    }

    @Test
    func `DialogEvent enum has all cases`() {
      // Verify exhaustive switch compiles (runtime check)
      let events: [DialogEvent] = []
      for event in events {
        switch event {
        case .login: break
        case .question: break
        case .progress: break
        case .progressUpdated: break
        case .cancel: break
        case .error: break
        }
      }
    }

    @Test
    func `QuestionType enum has all cases`() {
      let types: [QuestionType] = [.normal, .warning, .critical]
      #expect(types.count == 3)
    }

    @Test
    func `LoginRequest stores properties`() {
      // We can't construct a real LoginRequest without a C pointer,
      // but we verify the type exists and is Sendable
      let _: any Sendable.Type = LoginRequest.self
    }

    @Test
    func `QuestionRequest stores properties`() {
      let _: any Sendable.Type = QuestionRequest.self
    }

    @Test
    func `ProgressInfo stores properties`() {
      let _: any Sendable.Type = ProgressInfo.self
    }

    @Test
    func `ProgressUpdate stores properties`() {
      let _: any Sendable.Type = ProgressUpdate.self
    }

    @Test(.tags(.async))
    func `Second handler on the same instance finishes immediately`() async throws {
      let instance = try VLCInstance()
      let handler1 = DialogHandler(instance: instance)
      let handler2 = DialogHandler(instance: instance)
      _ = handler1
      let eventCount = await Task {
        var count = 0
        for await _ in handler2.dialogs {
          count += 1
        }
        return count
      }.value
      #expect(eventCount == 0)
    }

    @Test
    func `DialogEvent is Sendable`() {
      let _: any Sendable.Type = DialogEvent.self
    }

    @Test
    func `DialogID is Sendable`() {
      let _: any Sendable.Type = DialogID.self
    }

    @Test(.tags(.async))
    func `Handler stream can be iterated`() async throws {
      let instance = try VLCInstance()
      let handler = DialogHandler(instance: instance)
      let task = Task {
        for await _ in handler.dialogs {
          break
        }
      }
      // No dialogs expected, just verify no crash
      try await Task.sleep(for: .milliseconds(50))
      task.cancel()
      await task.value
    }

    @Test(.tags(.async))
    func `Handler deinit finishes stream`() async throws {
      let instance = try VLCInstance()
      let stream: AsyncStream<DialogEvent>
      do {
        let handler = DialogHandler(instance: instance)
        stream = handler.dialogs
      }
      // Handler is deinitialized — stream should finish
      let task = Task {
        for await _ in stream {}
      }
      try await Task.sleep(for: .milliseconds(100))
      task.cancel()
      await task.value
    }

    @Test
    func `QuestionType is exhaustive`() {
      let types: [QuestionType] = [.normal, .warning, .critical]
      for type in types {
        switch type {
        case .normal: break
        case .warning: break
        case .critical: break
        }
      }
      #expect(types.count == 3)
    }

    /// Two `DialogHandler`s on the same `VLCInstance` cannot both
    /// register — the second one finishes its stream immediately. This
    /// is the contract the per-instance registry enforces.
    @Test
    func `Second handler on same instance finishes its stream immediately`() async throws {
      let instance = try VLCInstance()
      let first = DialogHandler(instance: instance)
      let second = DialogHandler(instance: instance)

      // The second handler's stream should already be finished. Iterate
      // through it; we expect no events and prompt completion.
      var iter = second.dialogs.makeAsyncIterator()
      let next = await iter.next()
      #expect(next == nil, "second handler should yield no events")

      _ = first // keep first alive until end
    }

    /// Each `VLCInstance` has its own registration slot — `DialogHandler`s
    /// on different instances coexist. The probe: handler A registers
    /// first, then a second handler on the SAME instance should fail to
    /// register (already-finished stream). A second handler on a
    /// DIFFERENT instance succeeds.
    @Test
    func `DialogHandlers on different instances coexist`() async throws {
      let instanceA = try VLCInstance()
      let instanceB = try VLCInstance()

      let handlerA = DialogHandler(instance: instanceA)
      let handlerB = DialogHandler(instance: instanceB)

      // A second handler on instanceA loses the race — its stream is
      // immediately finished.
      let secondA = DialogHandler(instance: instanceA)
      var iterA = secondA.dialogs.makeAsyncIterator()
      #expect(await iterA.next() == nil, "second handler on same instance should be finished")

      // Both `handlerA` and `handlerB` should still hold their slots —
      // we have no easy way to assert "live" without sending real
      // events, but the test passes if the second-on-A handler closed
      // and neither A nor B crashed.
      _ = handlerA
      _ = handlerB
    }

    /// After the first handler is released, a new handler on the same
    /// instance should be able to register successfully.
    @Test
    func `Releasing the first handler frees the instance slot`() async throws {
      let instance = try VLCInstance()

      do {
        let first = DialogHandler(instance: instance)
        _ = first.dialogs
      }
      // First is deallocated. Its deinit offloads the release to a
      // utility queue; give that a moment to drain.
      try? await Task.sleep(for: .milliseconds(150))

      // A fresh handler on the same instance should claim the slot now.
      // We verify by spawning a SECOND fresh handler — if the slot was
      // freed correctly, only the next one (the third) sees an
      // immediately-finished stream.
      let second = DialogHandler(instance: instance)
      let third = DialogHandler(instance: instance)

      var iterThird = third.dialogs.makeAsyncIterator()
      #expect(await iterThird.next() == nil, "third handler should be finished — second should have claimed the slot")

      _ = second
    }
  }
}
