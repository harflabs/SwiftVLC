#if os(iOS)

/// A snapshot of libVLC's private native PiP machinery on iOS.
///
/// This is intentionally SPI, not stable public API. It exists for the
/// in-repo Showcase device-validation harness, which records how the
/// pinned libVLC binary wires its PiP window controller and
/// `AVPictureInPictureController` delegate. The shape of the probed
/// surface may change with any libVLC pin, and this type may change or
/// disappear with it, outside SwiftVLC's public semantic-versioning
/// contract.
@_spi(ValidationHarness)
public struct NativePiPProbe: Sendable {
  /// Runtime class name of libVLC's PiP window controller, if one has
  /// been handed over via the PiP-ready callback.
  public let windowControllerClassName: String?

  /// Whether the window controller exposed an
  /// `AVPictureInPictureController` through its `avPipController` key.
  public let hasAVController: Bool

  /// Runtime class name of the `AVPictureInPictureController`'s
  /// delegate, if any.
  public let avDelegateClassName: String?

  /// `respondsToSelector` results for the
  /// `AVPictureInPictureControllerDelegate` callbacks, keyed by
  /// selector name. Empty when no delegate is installed.
  public let delegateResponds: [String: Bool]

  /// The native backend's current possible flag.
  public let isPossible: Bool

  /// The native backend's current active flag.
  public let isActive: Bool
}

extension PiPController {
  /// A snapshot of the iOS native PiP backend's private wiring, or
  /// `nil` when this controller doesn't drive the native backend (the
  /// direct sample-buffer path).
  ///
  /// This is intentionally SPI, not stable public API. It exists for
  /// the in-repo Showcase device-validation harness and may change or
  /// disappear per libVLC pin, outside SwiftVLC's public
  /// semantic-versioning contract.
  @_spi(ValidationHarness)
  public var nativeValidationProbe: NativePiPProbe? {
    nativeBackend?.makeValidationProbe()
  }
}

#endif
