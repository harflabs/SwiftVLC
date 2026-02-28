import CLibVLC
import Foundation

/// Handles VLC dialog prompts (login, question, progress, error) via AsyncStream.
///
/// Register with a VLC instance to receive dialog events:
/// ```swift
/// let handler = DialogHandler(instance: .shared)
/// for await dialog in handler.dialogs {
///     switch dialog {
///     case let .login(request):
///         request.post(username: "user", password: "pass")
///     case let .question(request):
///         request.post(action: 1)
///     case let .progress(info):
///         print(info.title, info.position)
///     case let .error(title, message):
///         print("Error: \(title) - \(message)")
///     }
/// }
/// ```
public final class DialogHandler: @unchecked Sendable {
  private let instance: VLCInstance
  private let continuation: AsyncStream<DialogEvent>.Continuation
  private nonisolated(unsafe) var cbs: libvlc_dialog_cbs
  private nonisolated(unsafe) let boxOpaque: UnsafeMutableRawPointer

  /// Stream of dialog events from VLC.
  public let dialogs: AsyncStream<DialogEvent>

  /// Registers dialog callbacks with the given VLC instance.
  ///
  /// Only one dialog handler can be active per instance.
  /// - Parameter instance: The VLC instance to handle dialogs for.
  public init(instance: VLCInstance = .shared) {
    self.instance = instance

    let (stream, cont) = AsyncStream<DialogEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    dialogs = stream
    continuation = cont

    // Use a retained box so C callbacks always reference valid memory.
    // passUnretained(self) would be a use-after-free risk if a callback
    // fires during deinitialization.
    let box = Unmanaged.passRetained(DialogContinuationBox(continuation: cont)).toOpaque()
    boxOpaque = box

    cbs = libvlc_dialog_cbs(
      pf_display_login: dialogLoginCallback,
      pf_display_question: dialogQuestionCallback,
      pf_display_progress: dialogProgressCallback,
      pf_cancel: dialogCancelCallback,
      pf_update_progress: dialogUpdateProgressCallback
    )

    libvlc_dialog_set_callbacks(instance.pointer, &cbs, box)
    libvlc_dialog_set_error_callback(instance.pointer, dialogErrorCallback, box)
  }

  deinit {
    // Clear callbacks first (waits for in-progress callbacks to finish),
    // then release the box. This ordering guarantees no callback can
    // access the box after it's freed.
    libvlc_dialog_set_callbacks(instance.pointer, nil, nil)
    libvlc_dialog_set_error_callback(instance.pointer, nil, nil)
    continuation.finish()
    Unmanaged<DialogContinuationBox>.fromOpaque(boxOpaque).release()
  }
}

// MARK: - Internal Box

/// Retained by C callbacks via `Unmanaged.passRetained`. Outlives the
/// `DialogHandler` until explicitly released in deinit.
private final class DialogContinuationBox: @unchecked Sendable {
  let continuation: AsyncStream<DialogEvent>.Continuation
  init(continuation: AsyncStream<DialogEvent>.Continuation) {
    self.continuation = continuation
  }
}

// MARK: - Dialog Events

/// A dialog event emitted by VLC.
public enum DialogEvent: Sendable {
  /// VLC needs login credentials.
  case login(LoginRequest)
  /// VLC is asking a question (e.g. certificate trust).
  case question(QuestionRequest)
  /// VLC is displaying progress (e.g. downloading).
  case progress(ProgressInfo)
  /// Progress was updated.
  case progressUpdated(ProgressUpdate)
  /// VLC wants to cancel a previously shown dialog.
  case cancel(DialogID)
  /// VLC encountered an error to display.
  case error(title: String, message: String)
}

// MARK: - Dialog ID

/// An opaque identifier for an active dialog.
public struct DialogID: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_dialog_id*

  /// Dismisses the dialog.
  /// - Returns: `true` if the dialog was dismissed successfully.
  @discardableResult
  public func dismiss() -> Bool {
    libvlc_dialog_dismiss(pointer) == 0
  }
}

// MARK: - Login Request

/// A login dialog request from VLC (e.g. HTTP authentication).
public struct LoginRequest: Sendable {
  /// Identifier for this dialog instance.
  public let dialogId: DialogID
  /// Dialog title (e.g. the server name).
  public let title: String
  /// Descriptive text explaining why credentials are needed.
  public let text: String
  /// Pre-filled username, if available.
  public let defaultUsername: String
  /// Whether VLC offers to store credentials.
  public let askStore: Bool

  /// Posts a login response.
  /// - Returns: `true` if the credentials were accepted by VLC.
  @discardableResult
  public func post(username: String, password: String, store: Bool = false) -> Bool {
    libvlc_dialog_post_login(dialogId.pointer, username, password, store) == 0
  }

  /// Dismisses the login dialog without responding.
  /// - Returns: `true` if the dialog was dismissed successfully.
  @discardableResult
  public func dismiss() -> Bool {
    dialogId.dismiss()
  }
}

// MARK: - Question Request

/// The severity of a question dialog.
public enum QuestionType: Sendable {
  /// Standard informational question.
  case normal
  /// Non-critical warning requiring attention.
  case warning
  /// Security-sensitive or destructive action confirmation.
  case critical
}

/// A question dialog request from VLC (e.g. certificate trust prompt).
public struct QuestionRequest: Sendable {
  /// Identifier for this dialog instance.
  public let dialogId: DialogID
  /// Dialog title.
  public let title: String
  /// The question text.
  public let text: String
  /// Severity of the question.
  public let type: QuestionType
  /// Label for the cancel button.
  public let cancelText: String
  /// Label for the first action button, if available.
  public let action1Text: String?
  /// Label for the second action button, if available.
  public let action2Text: String?

  /// Posts a response.
  /// - Parameter action: `1` for ``action1Text``, `2` for ``action2Text``.
  /// - Returns: `true` if the response was accepted by VLC.
  @discardableResult
  public func post(action: Int) -> Bool {
    libvlc_dialog_post_action(dialogId.pointer, Int32(action)) == 0
  }

  /// Dismisses the question dialog.
  /// - Returns: `true` if the dialog was dismissed successfully.
  @discardableResult
  public func dismiss() -> Bool {
    dialogId.dismiss()
  }
}

// MARK: - Progress Info

/// A progress dialog from VLC (e.g. downloading a resource).
public struct ProgressInfo: Sendable {
  /// Identifier for this dialog instance.
  public let dialogId: DialogID
  /// Dialog title.
  public let title: String
  /// Descriptive text for the current operation.
  public let text: String
  /// Whether progress is indeterminate (spinner vs. progress bar).
  public let isIndeterminate: Bool
  /// Current progress (0.0...1.0). Meaningless when `isIndeterminate` is `true`.
  public let position: Float
  /// Label for the cancel button, or `nil` if not cancellable.
  public let cancelText: String?

  /// Dismisses the progress dialog.
  /// - Returns: `true` if the dialog was dismissed successfully.
  @discardableResult
  public func dismiss() -> Bool {
    dialogId.dismiss()
  }
}

/// An update to an existing progress dialog.
public struct ProgressUpdate: Sendable {
  /// Identifier for the dialog being updated.
  public let dialogId: DialogID
  /// Updated progress (0.0...1.0).
  public let position: Float
  /// Updated descriptive text.
  public let text: String
}

// MARK: - C Callbacks

private func dialogLoginCallback(
  _ data: UnsafeMutableRawPointer?,
  _ dialogId: OpaquePointer?,
  _ title: UnsafePointer<CChar>?,
  _ text: UnsafePointer<CChar>?,
  _ defaultUsername: UnsafePointer<CChar>?,
  _ askStore: Bool
) {
  guard let data, let dialogId, let title, let text else { return }
  let box = Unmanaged<DialogContinuationBox>.fromOpaque(data).takeUnretainedValue()
  box.continuation.yield(.login(LoginRequest(
    dialogId: DialogID(pointer: dialogId),
    title: String(cString: title),
    text: String(cString: text),
    defaultUsername: defaultUsername.map { String(cString: $0) } ?? "",
    askStore: askStore
  )))
}

private func dialogQuestionCallback(
  _ data: UnsafeMutableRawPointer?,
  _ dialogId: OpaquePointer?,
  _ title: UnsafePointer<CChar>?,
  _ text: UnsafePointer<CChar>?,
  _ type: libvlc_dialog_question_type,
  _ cancel: UnsafePointer<CChar>?,
  _ action1: UnsafePointer<CChar>?,
  _ action2: UnsafePointer<CChar>?
) {
  guard let data, let dialogId, let title, let text, let cancel else { return }
  let box = Unmanaged<DialogContinuationBox>.fromOpaque(data).takeUnretainedValue()

  let qType: QuestionType = switch type {
  case LIBVLC_DIALOG_QUESTION_WARNING: .warning
  case LIBVLC_DIALOG_QUESTION_CRITICAL: .critical
  default: .normal
  }

  box.continuation.yield(.question(QuestionRequest(
    dialogId: DialogID(pointer: dialogId),
    title: String(cString: title),
    text: String(cString: text),
    type: qType,
    cancelText: String(cString: cancel),
    action1Text: action1.map { String(cString: $0) },
    action2Text: action2.map { String(cString: $0) }
  )))
}

private func dialogProgressCallback(
  _ data: UnsafeMutableRawPointer?,
  _ dialogId: OpaquePointer?,
  _ title: UnsafePointer<CChar>?,
  _ text: UnsafePointer<CChar>?,
  _ indeterminate: Bool,
  _ position: Float,
  _ cancel: UnsafePointer<CChar>?
) {
  guard let data, let dialogId, let title, let text else { return }
  let box = Unmanaged<DialogContinuationBox>.fromOpaque(data).takeUnretainedValue()
  box.continuation.yield(.progress(ProgressInfo(
    dialogId: DialogID(pointer: dialogId),
    title: String(cString: title),
    text: String(cString: text),
    isIndeterminate: indeterminate,
    position: position,
    cancelText: cancel.map { String(cString: $0) }
  )))
}

private func dialogCancelCallback(
  _ data: UnsafeMutableRawPointer?,
  _ dialogId: OpaquePointer?
) {
  guard let data, let dialogId else { return }
  let box = Unmanaged<DialogContinuationBox>.fromOpaque(data).takeUnretainedValue()
  box.continuation.yield(.cancel(DialogID(pointer: dialogId)))
}

private func dialogUpdateProgressCallback(
  _ data: UnsafeMutableRawPointer?,
  _ dialogId: OpaquePointer?,
  _ position: Float,
  _ text: UnsafePointer<CChar>?
) {
  guard let data, let dialogId, let text else { return }
  let box = Unmanaged<DialogContinuationBox>.fromOpaque(data).takeUnretainedValue()
  box.continuation.yield(.progressUpdated(ProgressUpdate(
    dialogId: DialogID(pointer: dialogId),
    position: position,
    text: String(cString: text)
  )))
}

private func dialogErrorCallback(
  _ data: UnsafeMutableRawPointer?,
  _ title: UnsafePointer<CChar>?,
  _ text: UnsafePointer<CChar>?
) {
  guard let data, let title, let text else { return }
  let box = Unmanaged<DialogContinuationBox>.fromOpaque(data).takeUnretainedValue()
  box.continuation.yield(.error(
    title: String(cString: title),
    message: String(cString: text)
  ))
}
