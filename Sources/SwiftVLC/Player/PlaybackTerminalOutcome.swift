/// Why a playback generation ended.
public enum PlaybackTerminalCause: Hashable, Sendable {
  /// The input reached a clean end of stream.
  case naturalEnd
  /// The application explicitly asked the player to stop.
  case requestedStop
  /// A different media or native playback session replaced this generation.
  case replacement
  /// Player shutdown cancelled the generation before another terminal cause won.
  case cancellation
  /// Playback failed.
  case failure(PlaybackFailureKind)
  /// libVLC stopped without supplying an authoritative reason.
  case unknownNativeStop
}

/// The playback subsystem that failed, when SwiftVLC can identify it.
///
/// The bundled engine currently distinguishes a general playback error from
/// clean EOF and user stop, but does not attribute every error to a subsystem.
/// Such failures are reported as ``unknown`` instead of guessing from timing
/// or log text.
public enum PlaybackFailureKind: Hashable, Sendable {
  /// Media source or transport failed.
  case source
  /// Container or stream demultiplexing failed.
  case demux
  /// Audio, video, or subtitle decoding failed.
  case decoder
  /// Video rendering failed.
  case renderer
  /// Audio or video output failed.
  case output
  /// The engine reported failure without a reliable subsystem attribution.
  case unknown
}

/// Timeline and render state frozen before a terminal transition resets the
/// player's observable properties.
public struct PlaybackFinalTimeline: Hashable, Sendable {
  /// Last playback time reported for the generation.
  public let time: Duration
  /// Last known media duration.
  public let duration: Duration?
  /// Last fractional playback position.
  public let position: Double
  /// Last buffering fill level, normalized to `0.0 ... 1.0`.
  public let bufferFill: Float
  /// Last number of active native video outputs.
  public let activeVideoOutputs: Int
}

/// The immutable terminal result for one media generation.
public struct PlaybackTerminalOutcome: Hashable, Sendable {
  /// Media session this result belongs to.
  public let generation: PlaybackGeneration
  /// Native libVLC player that produced or was retired by the result.
  public let nativeGeneration: NativePlayerGeneration
  /// Authoritative cause when the engine or wrapper supplied one.
  public let cause: PlaybackTerminalCause
  /// State captured before terminal reset, identical for every subscriber.
  public let finalTimeline: PlaybackFinalTimeline
}

extension Player {
  /// Lossless terminal outcomes for active subscribers.
  ///
  /// Each playback generation is emitted at most once. The payload is frozen
  /// in the native event bridge before `.stopped` can clear ``currentTime``,
  /// ``position``, or ``bufferFill``. Unlike ``events``, this stream carries
  /// no high-frequency timing events and therefore uses an unbounded buffer so
  /// a stalled consumer cannot lose a one-shot result.
  public nonisolated var terminalOutcomes: AsyncStream<PlaybackTerminalOutcome> {
    eventBridge.makeTerminalOutcomeStream()
  }
}
