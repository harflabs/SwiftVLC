import SwiftVLC

/// Accepts the self-signed TLS certificate a Chromecast receiver presents
/// on its control connection.
///
/// Cast receivers authenticate with device certificates that no public
/// CA signs, so libVLC's TLS layer cannot validate them and asks the host
/// — through ``DialogHandler`` — whether to trust the connection. Google's
/// own senders accept these unconditionally; without an answer the
/// handshake fails and casting never connects. This responder answers the
/// trust question for the shared instance so the harness can exercise a
/// real cast.
///
/// A production app should scope acceptance to its cast flow (and may
/// surface the prompt to the user) rather than accept every certificate
/// question.
@MainActor
final class CastTrustResponder {
  static let shared = CastTrustResponder()

  private var handler: DialogHandler?
  private var task: Task<Void, Never>?

  func start() {
    guard handler == nil else { return }
    let handler = DialogHandler(instance: .shared)
    self.handler = handler
    let dialogs = handler.dialogs
    task = Task.detached {
      for await event in dialogs {
        guard case .question(let request) = event else { continue }
        if request.isCertificateTrust || request.isCastPerformanceWarning {
          request.post(action: 1)
        }
      }
    }
  }
}

extension QuestionRequest {
  fileprivate var isCertificateTrust: Bool {
    action1Text?.localizedCaseInsensitiveContains("certificate") == true
      || title.localizedCaseInsensitiveContains("insecure")
  }

  /// libVLC warns before casting a stream it must transcode (burning in a
  /// subtitle forces this). Accepting it lets the cast proceed.
  fileprivate var isCastPerformanceWarning: Bool {
    title.localizedCaseInsensitiveContains("performance")
  }
}
