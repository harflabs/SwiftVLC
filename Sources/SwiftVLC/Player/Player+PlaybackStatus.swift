/// The generation-scoped view of playback state.
///
/// Kept out of `Player.swift` so the core type stays under the file-length
/// limit, and because this is one coherent surface: a session identity and the
/// stream that reports state against it.
extension Player {
  /// The media session currently loaded.
  ///
  /// Advances on every media change, including ones SwiftVLC did not initiate.
  /// Capture it before work that spans a suspension point and compare it after
  /// to find out whether the session you started on is still the current one.
  public var generation: PlaybackGeneration {
    PlaybackGeneration(sessionGeneration)
  }

  /// Every playback state change, each tagged with the media session it belongs
  /// to, beginning with the current one.
  ///
  /// Unlike ``stateTransitions``, a subscriber that arrives late is told the
  /// current status immediately rather than waiting for the next change. State
  /// a consumer has to *know* cannot be learned from a stream that only carries
  /// transitions, and reading a property alongside races the stream it is meant
  /// to agree with.
  ///
  /// The generation is what makes a repeated state readable. Same-player media
  /// replacement produces a second `.playing` that is indistinguishable from
  /// the first on ``stateTransitions``; here the two carry different
  /// generations, so a consumer can tell a new session from a continuing one.
  ///
  /// Explicitly unbounded, for the same reason ``stateTransitions`` is: a
  /// stalled consumer must not silently lose a one-shot terminal state.
  ///
  /// ``stateTransitions`` deliberately does not replay. Consumers that
  /// subscribe in order to await the *next* occurrence of something — as
  /// ``recast(to:)`` does internally — would be handed a stale value from the
  /// outgoing session and act on it.
  public nonisolated var playbackStatus: AsyncStream<PlaybackStatus> {
    playbackStatusBridge.subscribeReplayingLatest(policy: .unbounded)
  }
}
