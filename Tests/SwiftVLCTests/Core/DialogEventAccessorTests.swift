@testable import SwiftVLC
import CustomDump
import Synchronization
import Testing

extension Logic {
  struct DialogEventAccessorTests {
    @Test
    func `Per-case accessors return associated payloads`() throws {
      let login = LoginRequest(
        dialogId: DialogID(pointer: SyntheticDialogPointer.next()),
        title: "Login",
        text: "Credentials required",
        defaultUsername: "guest",
        askStore: true
      )
      try expectNoDifference(#require(DialogEvent.login(login).login).title, "Login")

      let question = QuestionRequest(
        dialogId: DialogID(pointer: SyntheticDialogPointer.next()),
        title: "Trust",
        text: "Continue?",
        type: .critical,
        cancelText: "Cancel",
        action1Text: "Allow",
        action2Text: "Deny"
      )
      try expectNoDifference(#require(DialogEvent.question(question).question).type, .critical)

      let progress = ProgressInfo(
        dialogId: DialogID(pointer: SyntheticDialogPointer.next()),
        title: "Download",
        text: "Fetching",
        isIndeterminate: false,
        position: 0.25,
        cancelText: "Stop"
      )
      try expectNoDifference(#require(DialogEvent.progress(progress).progress).position, 0.25)

      let update = ProgressUpdate(
        dialogId: DialogID(pointer: SyntheticDialogPointer.next()),
        position: 0.5,
        text: "Halfway"
      )
      try expectNoDifference(#require(DialogEvent.progressUpdated(update).progressUpdated).text, "Halfway")

      let cancel = DialogID(pointer: SyntheticDialogPointer.next())
      #expect(try #require(DialogEvent.cancel(cancel).cancel)._isValidForTesting)

      let error = try #require(DialogEvent.error(title: "Network", message: "Denied").error)
      expectNoDifference(error.title, "Network")
      expectNoDifference(error.message, "Denied")
    }

    @Test
    func `Per-case accessors return nil for non-matching events`() {
      let event = DialogEvent.error(title: "Title", message: "Message")
      let nilResults = [
        event.login == nil,
        event.question == nil,
        event.progress == nil,
        event.progressUpdated == nil,
        event.cancel == nil,
        DialogEvent.cancel(DialogID(pointer: SyntheticDialogPointer.next())).error == nil
      ]

      expectNoDifference(nilResults, Array(repeating: true, count: nilResults.count))
    }

    @Test
    func `Request response helpers are one-shot safe`() {
      let loginId = DialogID(pointer: SyntheticDialogPointer.next())
      _ = loginId._consumeForTesting()
      let login = LoginRequest(
        dialogId: loginId,
        title: "Login",
        text: "Credentials required",
        defaultUsername: "",
        askStore: false
      )
      #expect(!login.post(username: "user", password: "pass"))
      #expect(!login.dismiss())

      let questionId = DialogID(pointer: SyntheticDialogPointer.next())
      let question = QuestionRequest(
        dialogId: questionId,
        title: "Question",
        text: "Pick one",
        type: .normal,
        cancelText: "Cancel",
        action1Text: "One",
        action2Text: nil
      )
      #expect(!question.post(action: Int.max))
      #expect(questionId._isValidForTesting, "Out-of-range action must not consume the dialog id")
      _ = questionId._consumeForTesting()
      #expect(!question.dismiss())

      let progressId = DialogID(pointer: SyntheticDialogPointer.next())
      _ = progressId._consumeForTesting()
      let progress = ProgressInfo(
        dialogId: progressId,
        title: "Progress",
        text: "Working",
        isIndeterminate: true,
        position: 0,
        cancelText: nil
      )
      #expect(!progress.dismiss())
    }
  }
}

private enum SyntheticDialogPointer {
  private static let counter = Mutex(0xC0FF_EE00)

  static func next() -> OpaquePointer {
    let address = counter.withLock { value -> Int in
      value += 16
      return value
    }
    return OpaquePointer(bitPattern: address)!
  }
}
