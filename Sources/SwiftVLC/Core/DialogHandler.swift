import CLibVLC
import Dispatch
import Foundation
import Synchronization

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
public final class DialogHandler: Sendable {
  private let instance: VLCInstance
  private let broadcaster: Broadcaster<DialogEvent>
  /// Token returned by `VLCInstance.claimDialogRegistration` on
  /// successful registration. `nil` when this handler lost the race
  /// to another `DialogHandler` that owns the slot.
  private let registrationToken: UUID?

  /// Stream of dialog events from VLC. A new independent stream is
  /// returned per access; subscribers don't compete for events.
  public var dialogs: AsyncStream<DialogEvent> {
    broadcaster.subscribe()
  }

  /// Registers dialog callbacks with the given VLC instance.
  ///
  /// Only one dialog handler can be active per instance. Additional handlers
  /// for the same instance finish their stream immediately instead of stealing
  /// callbacks from the active handler.
  /// - Parameter instance: The VLC instance to handle dialogs for.
  public init(instance: VLCInstance = .shared) {
    self.instance = instance

    let broadcaster = Broadcaster<DialogEvent>(defaultBufferSize: 16)
    self.broadcaster = broadcaster

    let box = Unmanaged.passRetained(broadcaster).toOpaque()

    if let token = instance.claimDialogRegistration(box: box) {
      // We won the slot — install C callbacks and remember the token.
      var cbs = libvlc_dialog_cbs(
        pf_display_login: dialogLoginCallback,
        pf_display_question: dialogQuestionCallback,
        pf_display_progress: dialogProgressCallback,
        pf_cancel: dialogCancelCallback,
        pf_update_progress: dialogUpdateProgressCallback
      )
      libvlc_dialog_set_callbacks(instance.pointer, &cbs, box)
      libvlc_dialog_set_error_callback(instance.pointer, dialogErrorCallback, box)
      registrationToken = token
    } else {
      // Another handler already owns this instance's dialog slot.
      // Release our box and terminate the broadcaster so any
      // `dialogs` access on this handler returns an immediately-
      // finished stream.
      Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(box).release()
      registrationToken = nil
      broadcaster.terminate()
    }
  }

  deinit {
    guard let token = registrationToken else {
      broadcaster.terminate()
      return
    }

    let instance = self.instance
    let broadcaster = self.broadcaster
    DispatchQueue.global(qos: .utility).async {
      // releaseDialogRegistration returns the box pointer if the token
      // still matches, so we can balance the Unmanaged retain. Token
      // mismatch (nil return) means something else cleared the slot —
      // shouldn't happen in practice but is benign.
      if let box = instance.releaseDialogRegistration(token: token) {
        libvlc_dialog_set_callbacks(instance.pointer, nil, nil)
        libvlc_dialog_set_error_callback(instance.pointer, nil, nil)
        Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(box).release()
      }
      broadcaster.terminate()
    }
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

// MARK: - DialogEvent per-case accessors

extension DialogEvent {
  /// `LoginRequest` if this event is `.login`, otherwise `nil`.
  public var login: LoginRequest? {
    if case .login(let value) = self { value } else { nil }
  }

  /// `QuestionRequest` if this event is `.question`, otherwise `nil`.
  public var question: QuestionRequest? {
    if case .question(let value) = self { value } else { nil }
  }

  /// `ProgressInfo` if this event is `.progress`, otherwise `nil`.
  public var progress: ProgressInfo? {
    if case .progress(let value) = self { value } else { nil }
  }

  /// `ProgressUpdate` if this event is `.progressUpdated`, otherwise `nil`.
  public var progressUpdated: ProgressUpdate? {
    if case .progressUpdated(let value) = self { value } else { nil }
  }

  /// `DialogID` if this event is `.cancel`, otherwise `nil`.
  public var cancel: DialogID? {
    if case .cancel(let value) = self { value } else { nil }
  }

  /// Tuple of `(title: String, message: String)` if this event is
  /// `.error`, otherwise `nil`.
  public var error: (title: String, message: String)? {
    if case .error(let title, let message) = self {
      (title: title, message: message)
    } else {
      nil
    }
  }
}

// MARK: - Dialog ID

/// A handle to an in-flight dialog issued by libVLC.
///
/// Each ``DialogEvent`` that represents a user-facing prompt carries
/// its own `DialogID`. Call ``dismiss()`` to close the dialog without
/// responding. This is useful when the UI showing the prompt is no
/// longer relevant, for example when the user navigated away or the
/// underlying operation was cancelled elsewhere.
public struct DialogID: Sendable {
  private let storage: DialogIDStorage

  init(pointer: OpaquePointer) {
    storage = DialogIDStorage.shared(for: pointer)
  }

  /// Dismisses the dialog without responding.
  ///
  /// Safe to call on an already-closed dialog; the return value
  /// reports whether libVLC acknowledged the dismissal.
  ///
  /// - Returns: `true` if libVLC accepted the dismissal.
  @discardableResult
  public func dismiss() -> Bool {
    consume { pointer in
      libvlc_dialog_dismiss(pointer) == 0
    }
  }

  @discardableResult
  func postLogin(username: String, password: String, store: Bool) -> Bool {
    consume { pointer in
      libvlc_dialog_post_login(pointer, username, password, store) == 0
    }
  }

  @discardableResult
  func postAction(_ action: Int) -> Bool {
    consume { pointer in
      libvlc_dialog_post_action(pointer, Int32(action)) == 0
    }
  }

  var pointer: OpaquePointer? {
    storage.currentPointer()
  }

  var _isValidForTesting: Bool {
    pointer != nil
  }

  @discardableResult
  func _consumeForTesting() -> OpaquePointer? {
    storage.consumePointer()
  }

  private func consume(_ operation: (OpaquePointer) -> Bool) -> Bool {
    guard let pointer = storage.consumePointer() else { return false }
    return operation(pointer)
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
    dialogId.postLogin(username: username, password: password, store: store)
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

  /// Posts the user's chosen action to libVLC.
  ///
  /// - Parameter action: `1` to pick the button labeled ``action1Text``,
  ///   or `2` to pick ``action2Text``. By convention `1` is the primary
  ///   (accept/allow) action and `2` is the secondary (reject/deny).
  /// - Returns: `true` if the response was accepted by libVLC.
  @discardableResult
  public func post(action: Int) -> Bool {
    dialogId.postAction(action)
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
  let broadcaster = Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(data).takeUnretainedValue()
  broadcaster.broadcast(.login(LoginRequest(
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
  let broadcaster = Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(data).takeUnretainedValue()

  let qType: QuestionType = switch type {
  case LIBVLC_DIALOG_QUESTION_WARNING: .warning
  case LIBVLC_DIALOG_QUESTION_CRITICAL: .critical
  default: .normal
  }

  broadcaster.broadcast(.question(QuestionRequest(
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
  let broadcaster = Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(data).takeUnretainedValue()
  broadcaster.broadcast(.progress(ProgressInfo(
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
  let broadcaster = Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(data).takeUnretainedValue()
  let dialog = DialogID(pointer: dialogId)
  broadcaster.broadcast(.cancel(dialog))
  _ = dialog.dismiss()
}

private func dialogUpdateProgressCallback(
  _ data: UnsafeMutableRawPointer?,
  _ dialogId: OpaquePointer?,
  _ position: Float,
  _ text: UnsafePointer<CChar>?
) {
  guard let data, let dialogId, let text else { return }
  let broadcaster = Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(data).takeUnretainedValue()
  broadcaster.broadcast(.progressUpdated(ProgressUpdate(
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
  let broadcaster = Unmanaged<Broadcaster<DialogEvent>>.fromOpaque(data).takeUnretainedValue()
  broadcaster.broadcast(.error(
    title: String(cString: title),
    message: String(cString: text)
  ))
}

private final class WeakDialogIDStorage: @unchecked Sendable {
  weak var value: DialogIDStorage?

  init(_ value: DialogIDStorage) {
    self.value = value
  }
}

private final class DialogIDStorage: @unchecked Sendable {
  private struct State: @unchecked Sendable {
    var pointer: OpaquePointer?
  }

  private static let registryQueue = DispatchQueue(label: "swiftvlc.dialog-id.registry")
  private nonisolated(unsafe) static var registry: [OpaquePointer: WeakDialogIDStorage] = [:]

  static func shared(for pointer: OpaquePointer) -> DialogIDStorage {
    registryQueue.sync {
      if let storage = registry[pointer]?.value {
        return storage
      }

      let storage = DialogIDStorage(pointer: pointer)
      registry[pointer] = WeakDialogIDStorage(storage)
      return storage
    }
  }

  private let key: OpaquePointer
  private let state: Mutex<State>

  private init(pointer: OpaquePointer) {
    key = pointer
    state = Mutex(State(pointer: pointer))
  }

  func currentPointer() -> OpaquePointer? {
    state.withLock { $0.pointer }
  }

  func consumePointer() -> OpaquePointer? {
    let pointer = state.withLock { state -> OpaquePointer? in
      let pointer = state.pointer
      state.pointer = nil
      return pointer
    }

    if pointer != nil {
      nonisolated(unsafe) let key = key
      Self.registryQueue.async {
        if Self.registry[key]?.value === self {
          Self.registry.removeValue(forKey: key)
        }
      }
    }

    return pointer
  }

  deinit {
    nonisolated(unsafe) let key = key
    Self.registryQueue.async {
      if Self.registry[key]?.value == nil {
        Self.registry.removeValue(forKey: key)
      }
    }
  }
}
