#if os(iOS) || os(macOS)

/// The immediate outcome of a ``PiPController/start()`` request.
///
/// This reports only whether the request was *issued*, not whether Picture in
/// Picture went on to appear. AVKit can still fail asynchronously after
/// accepting a start — a call arriving, the app losing audio focus, the system
/// declining under memory pressure — and those arrive on
/// ``PiPController/pipEvents`` as ordered lifecycle events. Keeping the two
/// separate matters: a caller that wants to fall back to full-screen playback
/// needs to know immediately that the request never left the building, and
/// waiting on an event that will never arrive is indistinguishable from waiting
/// on one that is merely slow.
public enum PiPStartResult: Sendable, Equatable {
  /// The backend start request was issued. Watch ``PiPController/pipEvents``
  /// for what happens next.
  case accepted

  /// No media is loaded, so there is nothing to show. Load media first.
  case noMedia

  /// Picture in Picture is unavailable in this environment — unsupported
  /// hardware, a simulator, or a system policy denying it. Mirrors
  /// ``PiPController/isPossible``.
  case notPossible

  /// A backend exists but its controller has not been created yet, so the
  /// request could not be handed anywhere. Usually a transient setup ordering
  /// problem: the video layer is not attached, or the controller is still
  /// being built.
  case backendUnavailable
}

#endif
