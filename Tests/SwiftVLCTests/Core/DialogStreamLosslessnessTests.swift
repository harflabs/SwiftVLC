@testable import SwiftVLC
import Synchronization
import Testing

/// Dialog events are requests, not notifications. VLC blocks until a login or
/// question is answered or dismissed, so a dropped one is a player that stops
/// with no UI to explain why.
///
/// The stream used to be bounded at newest-16 while `.progressUpdated` shared
/// it and arrives at whatever rate the underlying operation reports. The
/// consumer is a UI that stops to wait for a human — exactly when a
/// newest-wins buffer evicts its oldest entry, which is the prompt being
/// waited on.
@Suite(.tags(.logic))
struct DialogStreamLosslessnessTests {
  /// Fake dialog ids. Never dereferenced — `DialogID` only stores the pointer,
  /// and nothing in these tests answers a dialog.
  private static func syntheticDialogID() -> DialogID {
    let address = counter.withLock { value -> Int in
      value += 16
      return value
    }
    return DialogID(pointer: OpaquePointer(bitPattern: address)!)
  }

  private static let counter = Mutex(0x0BAD_F00D)

  private func loginRequest() -> LoginRequest {
    LoginRequest(
      dialogId: Self.syntheticDialogID(),
      title: "Server Auth",
      text: "Credentials required",
      defaultUsername: "guest",
      askStore: false
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func `A progress burst cannot evict a login prompt`() async {
    // A fresh instance per test: DialogHandler finishes its stream immediately
    // if another handler already owns the instance's dialog slot, so sharing
    // one would make these pass or fail on test ordering. It did — this was
    // green on macOS and red on tvOS before the instance was isolated.
    let handler = DialogHandler(instance: TestInstance.makeAudioOnly())
    let dialogs = handler.dialogs

    // Broadcast before draining, so the whole burst sits in the subscriber's
    // buffer at once — the condition a bounded policy truncates. The login
    // goes first, on the oldest side, where newest-wins evicts.
    handler.broadcaster.broadcast(.login(loginRequest()))
    for index in 0..<200 {
      handler.broadcaster.broadcast(
        .progressUpdated(
          ProgressUpdate(
            dialogId: Self.syntheticDialogID(),
            position: Float(index) / 200,
            text: "Downloading"
          )
        )
      )
    }
    // Bounds the drain without a timeout.
    handler.broadcaster.terminate()

    var sawLogin = false
    for await event in dialogs where event.login != nil {
      sawLogin = true
    }

    #expect(
      sawLogin,
      "a progress burst evicted the login prompt; VLC would wait forever for a reply that no UI ever asked for"
    )
  }

  /// `.cancel` is the only signal that a dialog already on screen is gone.
  /// Losing it leaves the app showing a prompt whose id no longer resolves.
  @Test(.timeLimit(.minutes(1)))
  func `A progress burst cannot evict a cancellation`() async {
    // A fresh instance per test: DialogHandler finishes its stream immediately
    // if another handler already owns the instance's dialog slot, so sharing
    // one would make these pass or fail on test ordering. It did — this was
    // green on macOS and red on tvOS before the instance was isolated.
    let handler = DialogHandler(instance: TestInstance.makeAudioOnly())
    let dialogs = handler.dialogs
    let cancelled = Self.syntheticDialogID()

    handler.broadcaster.broadcast(.cancel(cancelled))
    for index in 0..<200 {
      handler.broadcaster.broadcast(
        .progressUpdated(
          ProgressUpdate(
            dialogId: Self.syntheticDialogID(),
            position: Float(index) / 200,
            text: "Working"
          )
        )
      )
    }
    handler.broadcaster.terminate()

    var sawCancel = false
    for await event in dialogs {
      if case .cancel(let id) = event, id.pointer == cancelled.pointer {
        sawCancel = true
      }
    }

    #expect(sawCancel, "a progress burst evicted a dialog cancellation")
  }

  /// Ordering still holds: a lossless stream that reordered would be no more
  /// usable than a lossy one, since answering the wrong prompt is worse than
  /// answering none.
  @Test(.timeLimit(.minutes(1)))
  func `Events arrive in the order they were broadcast`() async {
    // A fresh instance per test: DialogHandler finishes its stream immediately
    // if another handler already owns the instance's dialog slot, so sharing
    // one would make these pass or fail on test ordering. It did — this was
    // green on macOS and red on tvOS before the instance was isolated.
    let handler = DialogHandler(instance: TestInstance.makeAudioOnly())
    let dialogs = handler.dialogs

    let positions: [Float] = [0.1, 0.2, 0.3, 0.4]
    for position in positions {
      handler.broadcaster.broadcast(
        .progressUpdated(
          ProgressUpdate(dialogId: Self.syntheticDialogID(), position: position, text: "x")
        )
      )
    }
    handler.broadcaster.terminate()

    var received: [Float] = []
    for await event in dialogs {
      if case .progressUpdated(let update) = event {
        received.append(update.position)
      }
    }

    #expect(received == positions, "dialog events were reordered: \(received)")
  }
}
