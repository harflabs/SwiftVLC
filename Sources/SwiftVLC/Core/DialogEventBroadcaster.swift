import Dispatch
import Foundation

/// Serializes subscription with prompt publication so late consumers cannot
/// miss a request between reading outstanding prompts and subscribing.
final class DialogEventBroadcaster: @unchecked Sendable {
  private let queue = DispatchQueue(label: "swiftvlc.dialog-events")
  // All mutable state belongs to queue. Termination handlers enqueue their
  // removal asynchronously: yielding can never wait on a cancellation handler
  // that is itself waiting to enter this queue.
  private var subscribers: [UUID: AsyncStream<DialogEvent>.Continuation] = [:]
  private var outstanding: [DialogEvent] = []
  private var terminated = false

  func subscribe() -> AsyncStream<DialogEvent> {
    let (stream, continuation) = AsyncStream<DialogEvent>.makeStream(bufferingPolicy: .unbounded)
    let id = UUID()
    queue.sync {
      guard !terminated else {
        continuation.finish()
        return
      }
      outstanding.removeAll { $0.dialogID?.pointer == nil }
      for event in outstanding {
        continuation.yield(event)
      }
      subscribers[id] = continuation
    }
    continuation.onTermination = { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.subscribers.removeValue(forKey: id)
      }
    }
    return stream
  }

  func broadcast(_ event: DialogEvent) {
    queue.sync {
      guard !terminated else { return }
      outstanding.removeAll { $0.dialogID?.pointer == nil }
      switch event {
      case .login, .question, .progress:
        if let id = event.dialogID, id.pointer != nil {
          outstanding.removeAll { $0.dialogID?.identity == id.identity }
          outstanding.append(event)
        }
      case .cancel(let id):
        outstanding.removeAll { $0.dialogID?.identity == id.identity }
      case .progressUpdated(let update):
        if
          let index = outstanding.firstIndex(where: { $0.dialogID?.identity == update.dialogId.identity }),
          case .progress(let info) = outstanding[index] {
          outstanding[index] = .progress(ProgressInfo(
            dialogId: info.dialogId,
            title: info.title,
            text: update.text,
            isIndeterminate: info.isIndeterminate,
            position: update.position,
            cancelText: info.cancelText
          ))
        }
      case .error:
        break
      }
      for continuation in subscribers.values {
        continuation.yield(event)
      }
    }
  }

  func terminate() {
    let continuations = queue.sync {
      terminated = true
      outstanding.removeAll()
      let continuations = Array(subscribers.values)
      subscribers.removeAll()
      return continuations
    }
    for continuation in continuations {
      continuation.finish()
    }
  }
}

extension DialogEvent {
  fileprivate var dialogID: DialogID? {
    switch self {
    case .login(let request): request.dialogId
    case .question(let request): request.dialogId
    case .progress(let info): info.dialogId
    case .progressUpdated(let update): update.dialogId
    case .cancel(let id): id
    case .error: nil
    }
  }
}
