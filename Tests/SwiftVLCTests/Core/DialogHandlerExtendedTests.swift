@testable import SwiftVLC
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct DialogHandlerExtendedTests {
  // MARK: - Helper

  /// Creates a dummy `OpaquePointer` backed by allocated memory.
  /// Returns both the opaque pointer and the raw pointer (for deallocation).
  private static func makeDummyPointer() -> (OpaquePointer, UnsafeMutableRawPointer) {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    raw.storeBytes(of: 0, as: Int.self)
    return (OpaquePointer(raw), raw)
  }

  // MARK: - DialogID

  @Test
  func `DialogID stores pointer`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let dialogId = DialogID(pointer: ptr)
    #expect(dialogId.pointer == ptr)
  }

  @Test
  func `DialogID is Sendable value type`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let id1 = DialogID(pointer: ptr)
    let id2 = id1 // copy
    #expect(id1.pointer == id2.pointer)

    // Sendable conformance
    let _: any Sendable = id1
  }

  // MARK: - LoginRequest

  @Test
  func `LoginRequest stores all properties`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let dialogId = DialogID(pointer: ptr)
    let request = LoginRequest(
      dialogId: dialogId,
      title: "Server Auth",
      text: "Enter credentials for example.com",
      defaultUsername: "admin",
      askStore: true
    )

    #expect(request.title == "Server Auth")
    #expect(request.text == "Enter credentials for example.com")
    #expect(request.defaultUsername == "admin")
    #expect(request.askStore == true)
    #expect(request.dialogId.pointer == ptr)
  }

  @Test
  func `LoginRequest with empty default username`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = LoginRequest(
      dialogId: DialogID(pointer: ptr),
      title: "Login",
      text: "Please log in",
      defaultUsername: "",
      askStore: false
    )

    #expect(request.defaultUsername.isEmpty)
    #expect(request.askStore == false)
  }

  @Test
  func `LoginRequest is Sendable`() {
    let _: any Sendable.Type = LoginRequest.self
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = LoginRequest(
      dialogId: DialogID(pointer: ptr),
      title: "T", text: "X", defaultUsername: "", askStore: false
    )
    let _: any Sendable = request
  }

  // MARK: - QuestionRequest

  @Test
  func `QuestionRequest stores all properties with both actions`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = QuestionRequest(
      dialogId: DialogID(pointer: ptr),
      title: "Certificate Trust",
      text: "Do you trust this certificate?",
      type: .critical,
      cancelText: "Cancel",
      action1Text: "Accept",
      action2Text: "Reject"
    )

    #expect(request.title == "Certificate Trust")
    #expect(request.text == "Do you trust this certificate?")
    #expect(request.type == .critical)
    #expect(request.cancelText == "Cancel")
    #expect(request.action1Text == "Accept")
    #expect(request.action2Text == "Reject")
    #expect(request.dialogId.pointer == ptr)
  }

  @Test
  func `QuestionRequest with nil action texts`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = QuestionRequest(
      dialogId: DialogID(pointer: ptr),
      title: "Question",
      text: "Continue?",
      type: .normal,
      cancelText: "No",
      action1Text: nil,
      action2Text: nil
    )

    #expect(request.action1Text == nil)
    #expect(request.action2Text == nil)
  }

  @Test
  func `QuestionRequest with only action1`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = QuestionRequest(
      dialogId: DialogID(pointer: ptr),
      title: "Warning",
      text: "Proceed?",
      type: .warning,
      cancelText: "Cancel",
      action1Text: "OK",
      action2Text: nil
    )

    #expect(request.action1Text == "OK")
    #expect(request.action2Text == nil)
    #expect(request.type == .warning)
  }

  @Test
  func `QuestionRequest is Sendable`() {
    let _: any Sendable.Type = QuestionRequest.self
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = QuestionRequest(
      dialogId: DialogID(pointer: ptr),
      title: "T", text: "X", type: .normal,
      cancelText: "C", action1Text: nil, action2Text: nil
    )
    let _: any Sendable = request
  }

  // MARK: - QuestionType

  @Test
  func `QuestionType switch covers all cases`() {
    let cases: [QuestionType] = [.normal, .warning, .critical]

    for qType in cases {
      let label = switch qType {
      case .normal: "normal"
      case .warning: "warning"
      case .critical: "critical"
      }
      #expect(!label.isEmpty)
    }
  }

  @Test
  func `QuestionType equality`() {
    // QuestionType cases are distinct
    let normal: QuestionType = .normal
    let warning: QuestionType = .warning
    let critical: QuestionType = .critical

    #expect(normal != warning)
    #expect(warning != critical)
    #expect(normal != critical)

    // Same cases are equal
    let normal2: QuestionType = .normal
    #expect(normal == normal2)
  }

  // MARK: - ProgressInfo

  @Test
  func `ProgressInfo stores all properties with cancelText`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let info = ProgressInfo(
      dialogId: DialogID(pointer: ptr),
      title: "Downloading",
      text: "Fetching subtitles...",
      isIndeterminate: false,
      position: 0.42,
      cancelText: "Abort"
    )

    #expect(info.title == "Downloading")
    #expect(info.text == "Fetching subtitles...")
    #expect(info.isIndeterminate == false)
    #expect(info.position == 0.42 as Float)
    #expect(info.cancelText == "Abort")
    #expect(info.dialogId.pointer == ptr)
  }

  @Test
  func `ProgressInfo with nil cancelText`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let info = ProgressInfo(
      dialogId: DialogID(pointer: ptr),
      title: "Loading",
      text: "Please wait",
      isIndeterminate: true,
      position: 0.0,
      cancelText: nil
    )

    #expect(info.cancelText == nil)
    #expect(info.isIndeterminate == true)
    #expect(info.position == 0.0)
  }

  @Test
  func `ProgressInfo is Sendable`() {
    let _: any Sendable.Type = ProgressInfo.self
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let info = ProgressInfo(
      dialogId: DialogID(pointer: ptr),
      title: "T", text: "X", isIndeterminate: false,
      position: 0, cancelText: nil
    )
    let _: any Sendable = info
  }

  // MARK: - ProgressUpdate

  @Test
  func `ProgressUpdate stores all properties`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let update = ProgressUpdate(
      dialogId: DialogID(pointer: ptr),
      position: 0.75,
      text: "75% complete"
    )

    #expect(update.position == 0.75 as Float)
    #expect(update.text == "75% complete")
    #expect(update.dialogId.pointer == ptr)
  }

  @Test
  func `ProgressUpdate at zero and full`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let zero = ProgressUpdate(
      dialogId: DialogID(pointer: ptr),
      position: 0.0,
      text: "Starting"
    )
    #expect(zero.position == 0.0)

    let full = ProgressUpdate(
      dialogId: DialogID(pointer: ptr),
      position: 1.0,
      text: "Complete"
    )
    #expect(full.position == 1.0)
  }

  @Test
  func `ProgressUpdate is Sendable`() {
    let _: any Sendable.Type = ProgressUpdate.self
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let update = ProgressUpdate(
      dialogId: DialogID(pointer: ptr),
      position: 0.5, text: "Half"
    )
    let _: any Sendable = update
  }

  // MARK: - DialogEvent pattern matching

  @Test
  func `DialogEvent login case pattern match`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = LoginRequest(
      dialogId: DialogID(pointer: ptr),
      title: "Auth", text: "Login needed",
      defaultUsername: "user", askStore: false
    )
    let event = DialogEvent.login(request)

    if case .login(let r) = event {
      #expect(r.title == "Auth")
      #expect(r.defaultUsername == "user")
    } else {
      Issue.record("Expected .login case")
    }
  }

  @Test
  func `DialogEvent question case pattern match`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let request = QuestionRequest(
      dialogId: DialogID(pointer: ptr),
      title: "Trust?", text: "Trust certificate?",
      type: .warning, cancelText: "No",
      action1Text: "Yes", action2Text: "Always"
    )
    let event = DialogEvent.question(request)

    if case .question(let q) = event {
      #expect(q.title == "Trust?")
      #expect(q.type == .warning)
      #expect(q.action1Text == "Yes")
      #expect(q.action2Text == "Always")
    } else {
      Issue.record("Expected .question case")
    }
  }

  @Test
  func `DialogEvent progress case pattern match`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let info = ProgressInfo(
      dialogId: DialogID(pointer: ptr),
      title: "Download", text: "Downloading...",
      isIndeterminate: false, position: 0.3,
      cancelText: "Cancel"
    )
    let event = DialogEvent.progress(info)

    if case .progress(let p) = event {
      #expect(p.title == "Download")
      #expect(p.position == 0.3 as Float)
      #expect(p.cancelText == "Cancel")
    } else {
      Issue.record("Expected .progress case")
    }
  }

  @Test
  func `DialogEvent progressUpdated case pattern match`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let update = ProgressUpdate(
      dialogId: DialogID(pointer: ptr),
      position: 0.9, text: "Almost done"
    )
    let event = DialogEvent.progressUpdated(update)

    if case .progressUpdated(let u) = event {
      #expect(u.position == 0.9 as Float)
      #expect(u.text == "Almost done")
    } else {
      Issue.record("Expected .progressUpdated case")
    }
  }

  @Test
  func `DialogEvent cancel case pattern match`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let dialogId = DialogID(pointer: ptr)
    let event = DialogEvent.cancel(dialogId)

    if case .cancel(let id) = event {
      #expect(id.pointer == ptr)
    } else {
      Issue.record("Expected .cancel case")
    }
  }

  @Test
  func `DialogEvent error case pattern match`() {
    let event = DialogEvent.error(title: "Network Error", message: "Connection refused")

    if case .error(let title, let message) = event {
      #expect(title == "Network Error")
      #expect(message == "Connection refused")
    } else {
      Issue.record("Expected .error case")
    }
  }

  @Test
  func `DialogEvent error with empty strings`() {
    let event = DialogEvent.error(title: "", message: "")

    if case .error(let title, let message) = event {
      #expect(title.isEmpty)
      #expect(message.isEmpty)
    } else {
      Issue.record("Expected .error case")
    }
  }

  @Test
  func `DialogEvent exhaustive switch on all cases`() {
    let (ptr, raw) = Self.makeDummyPointer()
    defer { raw.deallocate() }

    let dialogId = DialogID(pointer: ptr)

    let events: [DialogEvent] = [
      .login(LoginRequest(
        dialogId: dialogId, title: "T", text: "X",
        defaultUsername: "", askStore: false
      )),
      .question(QuestionRequest(
        dialogId: dialogId, title: "T", text: "X",
        type: .normal, cancelText: "C",
        action1Text: nil, action2Text: nil
      )),
      .progress(ProgressInfo(
        dialogId: dialogId, title: "T", text: "X",
        isIndeterminate: true, position: 0, cancelText: nil
      )),
      .progressUpdated(ProgressUpdate(
        dialogId: dialogId, position: 0.5, text: "X"
      )),
      .cancel(dialogId),
      .error(title: "E", message: "M")
    ]

    #expect(events.count == 6)

    var loginCount = 0
    var questionCount = 0
    var progressCount = 0
    var progressUpdatedCount = 0
    var cancelCount = 0
    var errorCount = 0

    for event in events {
      switch event {
      case .login: loginCount += 1
      case .question: questionCount += 1
      case .progress: progressCount += 1
      case .progressUpdated: progressUpdatedCount += 1
      case .cancel: cancelCount += 1
      case .error: errorCount += 1
      }
    }

    #expect(loginCount == 1)
    #expect(questionCount == 1)
    #expect(progressCount == 1)
    #expect(progressUpdatedCount == 1)
    #expect(cancelCount == 1)
    #expect(errorCount == 1)
  }

  // MARK: - Handler lifecycle

  @Test
  func `Handler with custom instance`() throws {
    let instance = try VLCInstance()
    let handler = DialogHandler(instance: instance)
    _ = handler.dialogs
  }

  @Test
  func `Multiple handlers sequential creation and teardown`() throws {
    let instance = try VLCInstance()
    for _ in 0..<5 {
      let handler = DialogHandler(instance: instance)
      _ = handler.dialogs
      // handler deinits at end of each iteration
    }
  }

  @Test
  func `Handler on separate instances`() throws {
    let instance1 = try VLCInstance()
    let instance2 = try VLCInstance()
    let handler1 = DialogHandler(instance: instance1)
    let handler2 = DialogHandler(instance: instance2)
    _ = handler1.dialogs
    _ = handler2.dialogs
  }

  // MARK: - Async stream patterns

  @Test(.tags(.async))
  func `Stream cancellation is immediate`() async throws {
    let instance = try VLCInstance()
    let handler = DialogHandler(instance: instance)

    let task = Task {
      var count = 0
      for await _ in handler.dialogs {
        count += 1
      }
      return count
    }

    // Cancel immediately
    task.cancel()
    let count = await task.value
    #expect(count == 0)
  }

  @Test(.tags(.async))
  func `Multiple stream iterations on same handler`() async throws {
    let instance = try VLCInstance()
    let handler = DialogHandler(instance: instance)

    // Start two concurrent iterations
    let task1 = Task {
      for await _ in handler.dialogs {
        break
      }
    }
    let task2 = Task {
      for await _ in handler.dialogs {
        break
      }
    }

    try await Task.sleep(for: .milliseconds(50))
    task1.cancel()
    task2.cancel()
    await task1.value
    await task2.value
  }

  @Test(.tags(.async))
  func `Handler deinit during active iteration`() async throws {
    let instance = try VLCInstance()
    let stream: AsyncStream<DialogEvent>

    do {
      let handler = DialogHandler(instance: instance)
      stream = handler.dialogs

      // Start iteration before handler deinits
      let task = Task {
        for await _ in stream {
          break
        }
      }

      try await Task.sleep(for: .milliseconds(20))
      task.cancel()
      await task.value
    }
    // handler is now deinitialized, stream should be finished

    // Iterating a finished stream should return immediately
    let task = Task {
      var count = 0
      for await _ in stream {
        count += 1
      }
      return count
    }
    let count = await task.value
    #expect(count == 0)
  }
}
