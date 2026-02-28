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
    private var cbs: libvlc_dialog_cbs

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

        cbs = libvlc_dialog_cbs(
            pf_display_login: dialogLoginCallback,
            pf_display_question: dialogQuestionCallback,
            pf_display_progress: dialogProgressCallback,
            pf_cancel: dialogCancelCallback,
            pf_update_progress: dialogUpdateProgressCallback
        )

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        libvlc_dialog_set_callbacks(instance.pointer, &cbs, opaque)
        libvlc_dialog_set_error_callback(instance.pointer, dialogErrorCallback, opaque)
    }

    deinit {
        libvlc_dialog_set_callbacks(instance.pointer, nil, nil)
        libvlc_dialog_set_error_callback(instance.pointer, nil, nil)
        continuation.finish()
    }

    fileprivate func yield(_ event: DialogEvent) {
        continuation.yield(event)
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
    @discardableResult
    public func dismiss() -> Bool {
        libvlc_dialog_dismiss(pointer) == 0
    }
}

// MARK: - Login Request

/// A login dialog request.
public struct LoginRequest: Sendable {
    public let dialogId: DialogID
    public let title: String
    public let text: String
    public let defaultUsername: String
    public let askStore: Bool

    /// Posts a login response.
    @discardableResult
    public func post(username: String, password: String, store: Bool = false) -> Bool {
        libvlc_dialog_post_login(dialogId.pointer, username, password, store) == 0
    }

    /// Dismisses the login dialog without responding.
    @discardableResult
    public func dismiss() -> Bool {
        dialogId.dismiss()
    }
}

// MARK: - Question Request

/// The severity of a question dialog.
public enum QuestionType: Sendable {
    case normal
    case warning
    case critical
}

/// A question dialog request.
public struct QuestionRequest: Sendable {
    public let dialogId: DialogID
    public let title: String
    public let text: String
    public let type: QuestionType
    public let cancelText: String
    public let action1Text: String?
    public let action2Text: String?

    /// Posts a response (1 for action1, 2 for action2).
    @discardableResult
    public func post(action: Int) -> Bool {
        libvlc_dialog_post_action(dialogId.pointer, Int32(action)) == 0
    }

    /// Dismisses the question dialog.
    @discardableResult
    public func dismiss() -> Bool {
        dialogId.dismiss()
    }
}

// MARK: - Progress Info

/// A progress dialog.
public struct ProgressInfo: Sendable {
    public let dialogId: DialogID
    public let title: String
    public let text: String
    public let isIndeterminate: Bool
    public let position: Float
    public let cancelText: String?

    /// Dismisses the progress dialog.
    @discardableResult
    public func dismiss() -> Bool {
        dialogId.dismiss()
    }
}

/// A progress dialog update.
public struct ProgressUpdate: Sendable {
    public let dialogId: DialogID
    public let position: Float
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
    let handler = Unmanaged<DialogHandler>.fromOpaque(data).takeUnretainedValue()
    handler.yield(.login(LoginRequest(
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
    let handler = Unmanaged<DialogHandler>.fromOpaque(data).takeUnretainedValue()

    let qType: QuestionType
    switch type {
    case LIBVLC_DIALOG_QUESTION_WARNING: qType = .warning
    case LIBVLC_DIALOG_QUESTION_CRITICAL: qType = .critical
    default: qType = .normal
    }

    handler.yield(.question(QuestionRequest(
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
    let handler = Unmanaged<DialogHandler>.fromOpaque(data).takeUnretainedValue()
    handler.yield(.progress(ProgressInfo(
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
    let handler = Unmanaged<DialogHandler>.fromOpaque(data).takeUnretainedValue()
    handler.yield(.cancel(DialogID(pointer: dialogId)))
}

private func dialogUpdateProgressCallback(
    _ data: UnsafeMutableRawPointer?,
    _ dialogId: OpaquePointer?,
    _ position: Float,
    _ text: UnsafePointer<CChar>?
) {
    guard let data, let dialogId, let text else { return }
    let handler = Unmanaged<DialogHandler>.fromOpaque(data).takeUnretainedValue()
    handler.yield(.progressUpdated(ProgressUpdate(
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
    let handler = Unmanaged<DialogHandler>.fromOpaque(data).takeUnretainedValue()
    handler.yield(.error(
        title: String(cString: title),
        message: String(cString: text)
    ))
}
