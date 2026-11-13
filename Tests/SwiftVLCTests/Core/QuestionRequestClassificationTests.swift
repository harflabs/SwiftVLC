@testable import SwiftVLC
import Synchronization
import Testing

extension Logic {
  struct QuestionRequestClassificationTests {
    private static func question(
      title: String,
      action1: String?,
      action2: String? = nil
    ) -> QuestionRequest {
      QuestionRequest(
        dialogId: DialogID(pointer: SyntheticDialogPointer.next()),
        title: title,
        text: "You attempted to reach 192.168.0.20. However the security certificate "
          + "presented by the server is unknown",
        type: .warning,
        cancelText: "Abort",
        action1Text: action1,
        action2Text: action2
      )
    }

    /// The exact strings `st_validateServerCertificate` passes to
    /// `vlc_dialog_wait_question` at the pinned libVLC revision. A fake Cast
    /// receiver run against the released library produces this question
    /// verbatim; if a libVLC update rewords it, casting stops connecting and
    /// this literal is the place to update.
    @Test
    func `The Apple TLS backend's untrusted-certificate question is recognised`() {
      let request = Self.question(
        title: "Insecure site",
        action1: "Accept certificate temporarily"
      )

      #expect(request.isCertificateTrustQuestion)
    }

    @Test(
      arguments: [
        ("Performance warning", "OK" as String?),
        ("Insecure site", "View certificate"),
        ("Insecure site", nil),
        ("insecure site", "Accept certificate temporarily"),
        ("Certificate Trust", "Accept certificate temporarily")
      ]
    )
    func `Other questions are not mistaken for certificate trust`(
      title: String,
      action1: String?
    ) {
      #expect(!Self.question(title: title, action1: action1).isCertificateTrustQuestion)
    }
  }
}

private enum SyntheticDialogPointer {
  private static let counter = Mutex(0xCA57_0000)

  static func next() -> OpaquePointer {
    let address = counter.withLock { value -> Int in
      value += 16
      return value
    }
    return OpaquePointer(bitPattern: address)!
  }
}
