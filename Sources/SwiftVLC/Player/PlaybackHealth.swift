/// The kind of media currently making forward playback progress.
public enum PlaybackContentKind: Sendable, Hashable {
  /// Audio is progressing and the session has no observed video output.
  case audioOnly
  /// Video is progressing and no audio progress has been observed.
  case videoOnly
  /// Audio and video are both progressing.
  case audiovisual
}

/// A non-terminal reason playback has not yet produced its next presentation.
public enum PlaybackWaitingReason: Sendable, Hashable {
  /// The input is still opening.
  case opening
  /// libVLC is filling its input buffer.
  case buffering
  /// Playback has started but the first video frame has not been presented.
  case firstFrame
  /// An accepted seek is waiting for presentation on the new timeline.
  case seeking
  /// A track/representation change is waiting for its first new presentation.
  case adaptiveSwitch
}

/// The pipeline stage that has stopped making progress.
public enum PlaybackStallReason: Sendable, Hashable {
  /// No source or demux bytes are arriving.
  case source
  /// Source bytes are arriving but neither decoder is advancing.
  case decoder
  /// Video is decoding but no frame reaches presentation.
  case display
  /// Audio is decoding but no audio buffer reaches the output.
  case audioOutput
  /// The sample-buffer renderer is applying bounded flush recovery.
  case rendererRecovery
}

/// Terminal playback-health failures.
public enum PlaybackHealthFailure: Sendable, Hashable {
  /// libVLC emitted an unrecoverable player error.
  case player
  /// The display renderer exhausted ten 16-millisecond flush retries.
  ///
  /// The failure is observed on the next health sample, so under normal
  /// scheduling the typed terminal event arrives within about 410 milliseconds
  /// of recovery beginning. System-level queue starvation can delay delivery.
  case renderer
}

/// Current semantic playback-health classification.
public enum PlaybackHealthState: Sendable, Hashable {
  /// No media is actively progressing.
  case idle
  /// Playback is paused intentionally; lack of progress is not a stall.
  case paused
  /// Playback is waiting for an expected pipeline transition.
  case waiting(PlaybackWaitingReason)
  /// The observed media pipeline is making forward progress.
  case healthy(PlaybackContentKind)
  /// The identified pipeline stage has not progressed for the stall threshold.
  case stalled(PlaybackStallReason)
  /// Playback cannot recover without a new command or media session.
  case failed(PlaybackHealthFailure)
}

/// Coarse status of the direct sample-buffer renderer.
public enum PlaybackRendererStatus: Sendable, Hashable {
  /// The current playback route does not expose renderer telemetry.
  case unavailable
  /// A renderer exists but has not accepted a frame yet.
  case idle
  /// Frames are reaching the display layer.
  case rendering
  /// The newest frame is replacing older work while the layer is saturated.
  case backpressured
  /// A flushed frame is being re-offered within the bounded retry budget.
  case recovering
  /// Bounded renderer recovery was exhausted.
  case failed
}

/// Bounded cumulative counters for one playback generation.
public struct PlaybackHealthCounters: Sendable, Hashable {
  /// Bytes read from the current input.
  public let sourceReadBytes: UInt64
  /// Bytes delivered by the demuxer for the current media.
  public let demuxReadBytes: UInt64
  /// Video frames decoded in this playback generation.
  public let decodedVideoFrames: UInt64
  /// Audio buffers decoded in this playback generation.
  public let decodedAudioFrames: UInt64
  /// Video frames offered to the direct sample-buffer renderer.
  public let enqueuedVideoFrames: UInt64
  /// Video frames accepted by the native or direct presentation path.
  public let presentedVideoFrames: UInt64
  /// Audio buffers accepted by the audio output.
  public let playedAudioBuffers: UInt64
  /// Video frames lost by libVLC or the direct renderer.
  public let droppedVideoFrames: UInt64
  /// Video frames reported late by libVLC.
  public let lateVideoFrames: UInt64
  /// Direct-renderer video-output generations created during playback.
  public let rendererRebuilds: UInt64
  /// Direct-renderer flushes used to resume presentation.
  public let rendererFlushes: UInt64
  /// Direct-renderer frames dropped because its queue was saturated.
  public let rendererBackpressureDrops: UInt64
  /// Pending direct-renderer frames superseded by a newer frame.
  public let rendererFrameReplacements: UInt64
  /// Attempts to re-offer a frame after a direct-renderer flush.
  public let rendererRecoveryRetries: UInt64
  /// Direct-renderer frames that exhausted bounded flush recovery.
  public let rendererRecoveryFailures: UInt64

  init(
    sourceReadBytes: UInt64 = 0,
    demuxReadBytes: UInt64 = 0,
    decodedVideoFrames: UInt64 = 0,
    decodedAudioFrames: UInt64 = 0,
    enqueuedVideoFrames: UInt64 = 0,
    presentedVideoFrames: UInt64 = 0,
    playedAudioBuffers: UInt64 = 0,
    droppedVideoFrames: UInt64 = 0,
    lateVideoFrames: UInt64 = 0,
    rendererRebuilds: UInt64 = 0,
    rendererFlushes: UInt64 = 0,
    rendererBackpressureDrops: UInt64 = 0,
    rendererFrameReplacements: UInt64 = 0,
    rendererRecoveryRetries: UInt64 = 0,
    rendererRecoveryFailures: UInt64 = 0
  ) {
    self.sourceReadBytes = sourceReadBytes
    self.demuxReadBytes = demuxReadBytes
    self.decodedVideoFrames = decodedVideoFrames
    self.decodedAudioFrames = decodedAudioFrames
    self.enqueuedVideoFrames = enqueuedVideoFrames
    self.presentedVideoFrames = presentedVideoFrames
    self.playedAudioBuffers = playedAudioBuffers
    self.droppedVideoFrames = droppedVideoFrames
    self.lateVideoFrames = lateVideoFrames
    self.rendererRebuilds = rendererRebuilds
    self.rendererFlushes = rendererFlushes
    self.rendererBackpressureDrops = rendererBackpressureDrops
    self.rendererFrameReplacements = rendererFrameReplacements
    self.rendererRecoveryRetries = rendererRecoveryRetries
    self.rendererRecoveryFailures = rendererRecoveryFailures
  }
}

/// Low-rate, generation-scoped playback-health state.
///
/// Frame timestamps are monotonic durations since this media generation began,
/// not wall-clock dates. Direct rendering is sampled at most four times per
/// second; no public event is emitted on every decoded frame.
public struct PlaybackHealthSnapshot: Sendable, Hashable {
  /// Media generation to which every value in the snapshot belongs.
  public let generation: PlaybackGeneration
  /// Current semantic classification of the playback pipeline.
  public let state: PlaybackHealthState
  /// Monotonic snapshot revision within this player instance.
  public let revision: UInt64
  /// Elapsed generation time of the latest decoded video frame.
  public let lastDecodedAt: Duration?
  /// Elapsed generation time of the latest direct-renderer enqueue.
  public let lastEnqueuedAt: Duration?
  /// Elapsed generation time of the latest presented video frame.
  public let lastPresentedAt: Duration?
  /// Current state of the direct sample-buffer renderer.
  public let rendererStatus: PlaybackRendererStatus
  /// Monotonic direct-renderer vout identity, or `nil` on native routes.
  public let voutGeneration: UInt64?
  /// Cumulative pipeline counters for this media generation.
  public let counters: PlaybackHealthCounters
  /// Most recent stall in this generation, retained after recovery so a late
  /// subscriber can reconstruct the paired stall/recovery transition.
  public let lastStallReason: PlaybackStallReason?
  /// Elapsed generation time when the most recent stall began.
  public let lastStalledAt: Duration?
  /// Elapsed generation time when the most recent stall recovered.
  public let lastRecoveredAt: Duration?

  init(
    generation: PlaybackGeneration,
    state: PlaybackHealthState,
    revision: UInt64,
    lastDecodedAt: Duration? = nil,
    lastEnqueuedAt: Duration? = nil,
    lastPresentedAt: Duration? = nil,
    rendererStatus: PlaybackRendererStatus = .unavailable,
    voutGeneration: UInt64? = nil,
    counters: PlaybackHealthCounters = PlaybackHealthCounters(),
    lastStallReason: PlaybackStallReason? = nil,
    lastStalledAt: Duration? = nil,
    lastRecoveredAt: Duration? = nil
  ) {
    self.generation = generation
    self.state = state
    self.revision = revision
    self.lastDecodedAt = lastDecodedAt
    self.lastEnqueuedAt = lastEnqueuedAt
    self.lastPresentedAt = lastPresentedAt
    self.rendererStatus = rendererStatus
    self.voutGeneration = voutGeneration
    self.counters = counters
    self.lastStallReason = lastStallReason
    self.lastStalledAt = lastStalledAt
    self.lastRecoveredAt = lastRecoveredAt
  }
}

/// A semantic transition on the playback-health timeline.
public enum PlaybackHealthEventKind: Sendable, Hashable {
  /// The first video frame was decoded for this media generation.
  case firstDecodedFrame
  /// The first video frame was presented for this media generation.
  case firstPresentedFrame
  /// Playback entered an expected non-terminal wait.
  case waiting(PlaybackWaitingReason)
  /// A pipeline stage exceeded the stall threshold.
  case stalled(PlaybackStallReason)
  /// Forward progress resumed after the identified stall.
  case recovered(from: PlaybackStallReason)
  /// Playback reached a typed failure that requires external action.
  case terminalFailure(PlaybackHealthFailure)
}

/// A playback-health transition together with the state it produced.
public struct PlaybackHealthEvent: Sendable, Hashable {
  /// Semantic transition represented by this event.
  public let kind: PlaybackHealthEventKind
  /// Snapshot produced by the transition.
  public let snapshot: PlaybackHealthSnapshot
}
