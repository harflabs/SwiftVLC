#if os(iOS) || os(macOS)

/// The immediate outcome of a ``PiPController/start()`` request.
///
/// This reports only whether the request was *issued*, not whether Picture in
/// Picture went on to appear. AVKit can still fail asynchronously after
/// accepting a start — a call arriving, the app losing audio focus, the system
/// declining under memory pressure — and those arrive on
/// ``PiPController/pipEventEnvelopes`` as ordered, generation-attributed
/// lifecycle events. The compatibility ``PiPController/pipEvents`` stream
/// carries the same transitions without their identities. Keeping the
/// immediate result and asynchronous lifecycle separate matters: a caller that
/// wants to fall back to full-screen playback needs to know immediately that
/// the request never left the building, and waiting on an event that will never
/// arrive is indistinguishable from waiting on one that is merely slow.
public enum PiPStartResult: Sendable, Equatable {
  /// The backend start request was issued. Watch
  /// ``PiPController/pipEventEnvelopes`` for what happens next.
  case accepted

  /// No media is loaded, so there is nothing to show. Load media first.
  case noMedia

  /// Picture in Picture is unavailable in this environment — unsupported
  /// hardware, a simulator, or a system policy denying it. Mirrors
  /// ``PiPController/isPossible``.
  case notPossible

  /// A backend exists but had nowhere to send the request.
  ///
  /// What reaches this case differs by backend, and the difference is worth
  /// knowing:
  ///
  /// - **Direct AVKit**: no `AVPictureInPictureController` was created.
  /// - **macOS native**: Picture in Picture is possible, but the host or
  ///   drawable view is not wired up yet — a genuine setup-ordering window.
  /// - **iOS native**: the window controller reference has gone. That
  ///   reference is weak, so this reports "was ready, no longer is" rather
  ///   than "not ready yet". Before the backend is ready at all, `isPossible`
  ///   is `false` and the request reports ``notPossible`` instead — iOS cannot
  ///   separate "still preparing" from "unsupported here" from the signals
  ///   AVKit gives it, so it reports the conservative one.
  ///
  /// In every case the request never left the controller, so retrying once the
  /// view hierarchy has settled is reasonable — unlike ``notPossible``, which
  /// on a given device may never change.
  case backendUnavailable
}

#endif
