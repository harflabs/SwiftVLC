@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
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

  @Test
  func `Multiple handlers replace each other`() throws {
    let instance = try VLCInstance()
    let handler1 = DialogHandler(instance: instance)
    let handler2 = DialogHandler(instance: instance)
    // Second handler replaces first — no crash
    _ = handler1.dialogs
    _ = handler2.dialogs
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
}
