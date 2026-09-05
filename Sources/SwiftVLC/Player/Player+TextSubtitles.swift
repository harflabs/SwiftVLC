import CLibVLC

extension Player {
  /// Creates a stream of the text subtitle currently displayed by libVLC for
  /// custom presentation.
  ///
  /// Calling this method for the first time opts the player into text capture
  /// and suppresses libVLC's native rendering of semantic text subtitle
  /// regions. Call it before the player's first successful `play` on its
  /// current native handle. Never calling it preserves ordinary native
  /// subtitle rendering.
  ///
  /// Each stream immediately yields the latest ordered region snapshot, using
  /// an empty `regions` array to mean that no captured subtitle is displayed,
  /// and then yields distinct text-or-placement changes with newest-one
  /// buffering. ``TextSubtitleSnapshot/text`` preserves the traditional
  /// flattened string as a convenience.
  ///
  /// Capture remains enabled for this `Player`'s lifetime even when every
  /// subscriber stops iterating. Native handle replacement reattaches capture
  /// before the successor can play and does not finish existing streams.
  ///
  /// - Returns: An independent stream of complete subtitle snapshots.
  /// - Throws: ``VLCError/invalidState(_:)`` when first enabled after playback
  ///   has started on the current native handle, or
  ///   ``VLCError/operationFailed(_:)`` when the linked libVLC does not provide
  ///   the text-subtitle callback extension or registration fails.
  public func textSubtitleStream() throws(VLCError) -> AsyncStream<TextSubtitleSnapshot> {
    try textSubtitleStream(using: .live)
  }

  /// Injectable counterpart used by lifecycle tests that run against the
  /// released libVLC artifact.
  func textSubtitleStream(
    using native: SubtitleTextNativeOperations
  )
    throws(VLCError) -> AsyncStream<TextSubtitleSnapshot> {
    if isTextSubtitleCaptureEnabled {
      return subtitleTextBridge.subscribe()
    }
    guard !isShutdown else {
      throw .invalidState("text subtitle capture cannot be enabled after shutdown")
    }
    guard !hasStartedNativePlaybackForTextSubtitleCapture else {
      throw .invalidState("textSubtitleStream() must be called before playback starts")
    }
    guard native.isAvailable() else {
      throw .operationFailed("Enable text subtitle capture (custom libVLC build required)")
    }
    guard attachTextSubtitleCapture(to: nativeHandleLifetime, using: native) else {
      if hasStartedNativePlaybackForTextSubtitleCapture {
        throw .invalidState("textSubtitleStream() must be called before playback starts")
      }
      throw .operationFailed("Register text subtitle callback")
    }

    subtitleTextNativeOperations = native
    isTextSubtitleCaptureEnabled = true
    return subtitleTextBridge.subscribe()
  }

  /// Reattaches an already-enabled capture bridge to a replacement native
  /// player. Called while the candidate handle is still private, before it can
  /// start playback or replace the outgoing pointer.
  func reattachTextSubtitleCaptureIfEnabled(
    to lifetime: NativePlayerHandleLifetime
  )
    throws(VLCError) {
    guard isTextSubtitleCaptureEnabled else { return }
    let native = subtitleTextNativeOperations
    guard native.isAvailable() else {
      throw .operationFailed("Reattach text subtitle capture")
    }
    guard attachTextSubtitleCapture(to: lifetime, using: native) else {
      throw .operationFailed("Reattach text subtitle capture")
    }
  }

  private func attachTextSubtitleCapture(
    to lifetime: NativePlayerHandleLifetime,
    using native: SubtitleTextNativeOperations
  ) -> Bool {
    subtitleTextBridge.attach(to: lifetime) { callback, opaque in
      native.register(lifetime.pointer, callback, opaque)
    }
  }

  /// Covers native drivers that bypass `Player.play()`, notably
  /// `MediaListPlayer`, plus the brief windows before observable state catches
  /// up with a newly created video output.
  private var hasStartedNativePlaybackForTextSubtitleCapture: Bool {
    if
      nativePlayerHasStartedPlayback
      || activeVideoOutputs > 0 {
      return true
    }

    switch nativePlaybackState {
    case .idle, .stopped, .error:
      return state.isActive || state == .stopping
    case .opening, .buffering, .playing, .paused, .stopping:
      return true
    }
  }

  /// Whether a same-handle reset must wait for the native output's ordered
  /// empty callback before accepting another nonempty cue.
  var hasLiveNativeOutputForTextSubtitleReset: Bool {
    // With capture disabled there is no registered callback, no retiring cue
    // to quarantine, and therefore no reason to cross into the native media
    // identity. This also keeps load/stop publication fail-closed when an
    // Observation callback has already made the current handle dormant.
    guard isTextSubtitleCaptureEnabled else { return false }

    // A subtitle callback can only originate from a video output. Do not use
    // the transport state here: audio-only playback has no SPU to publish the
    // ordered empty callback that releases the reset barrier. The mirrored
    // vout count covers established outputs, while the live decoded-size
    // probe closes the short window before the vout event reaches MainActor.
    return activeVideoOutputs > 0 || hasVideoOutput
  }
}
