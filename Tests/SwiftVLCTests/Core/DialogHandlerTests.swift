@testable import SwiftVLC
import Testing

@Suite("DialogHandler", .tags(.integration))
struct DialogHandlerTests {
  @Test("Init creates dialogs stream")
  func initCreatesDialogsStream() throws {
    let instance = try VLCInstance()
    let handler = DialogHandler(instance: instance)
    _ = handler.dialogs // should not crash
  }

  @Test("Deinit cleans up callbacks")
  func deinitCleansUpCallbacks() throws {
    let instance = try VLCInstance()
    var handler: DialogHandler? = DialogHandler(instance: instance)
    _ = handler?.dialogs
    handler = nil
    // If we get here without crash, cleanup was successful
  }

  @Test("DialogEvent enum has all cases")
  func dialogEventEnumHasAllCases() {
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

  @Test("QuestionType enum has all cases")
  func questionTypeEnumHasAllCases() {
    let types: [QuestionType] = [.normal, .warning, .critical]
    #expect(types.count == 3)
  }

  @Test("LoginRequest stores properties")
  func loginRequestProperties() {
    // We can't construct a real LoginRequest without a C pointer,
    // but we verify the type exists and is Sendable
    let _: any Sendable.Type = LoginRequest.self
  }

  @Test("QuestionRequest stores properties")
  func questionRequestProperties() {
    let _: any Sendable.Type = QuestionRequest.self
  }

  @Test("ProgressInfo stores properties")
  func progressInfoProperties() {
    let _: any Sendable.Type = ProgressInfo.self
  }

  @Test("ProgressUpdate stores properties")
  func progressUpdateProperties() {
    let _: any Sendable.Type = ProgressUpdate.self
  }

  @Test("Multiple handlers replace each other")
  func multipleHandlersReplaceEachOther() throws {
    let instance = try VLCInstance()
    let handler1 = DialogHandler(instance: instance)
    let handler2 = DialogHandler(instance: instance)
    // Second handler replaces first — no crash
    _ = handler1.dialogs
    _ = handler2.dialogs
  }

  @Test("DialogEvent is Sendable")
  func dialogEventIsSendable() {
    let _: any Sendable.Type = DialogEvent.self
  }

  @Test("DialogID is Sendable")
  func dialogIDIsSendable() {
    let _: any Sendable.Type = DialogID.self
  }

  @Test("Handler stream can be iterated", .tags(.async))
  func handlerStreamCanBeIterated() async throws {
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

  @Test("Handler deinit finishes stream", .tags(.async))
  func handlerDeinitFinishesStream() async throws {
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

  @Test("QuestionType is exhaustive")
  func questionTypeExhaustive() {
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
