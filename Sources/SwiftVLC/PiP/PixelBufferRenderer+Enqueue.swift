#if os(iOS) || os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

/// Carries media objects onto the serial enqueue queue. Pending ownership is
/// held by one replaceable slot, never by one closure per decoded frame.
struct EnqueuedSampleBuffer: @unchecked Sendable {
  let layer: AVSampleBufferDisplayLayer
  let sample: CMSampleBuffer
  let generation: UInt64
  let playbackGeneration: UInt64
  let voutGeneration: UInt64
}

struct PixelBufferEnqueueState: @unchecked Sendable {
  var pending: EnqueuedSampleBuffer?
  var isDrainScheduled = false
  var scheduledDrainCount: UInt64 = 0
  var drainedSampleCount: UInt64 = 0
  var replacementCount: UInt64 = 0
  /// Consecutive re-offers of the frame that triggered a flush. Reset by a
  /// delivery or by a newer frame taking the slot.
  var flushRecoveryRetryCount: UInt64 = 0
  /// The render generation the in-progress recovery belongs to. Recovery is
  /// scoped to it so a replacement cannot inherit the retry budget and turn
  /// the next generation's plain backpressure into retention.
  var flushRecoveryGeneration: UInt64?
  /// Unrecoverable display transitions. This includes a flush recovery that
  /// exhausted its retry budget and a renderer whose `.failed` state did not
  /// explicitly advertise `requiresFlushToResumeDecoding`. A non-zero value
  /// is an observable terminal failure, never a successful frame delivery.
  var flushRecoveryFailureCount: UInt64 = 0
  var flushRecoveryTotalRetryCount: UInt64 = 0
  var enqueuedFrameCount: UInt64 = 0
  var presentedFrameCount: UInt64 = 0
  var flushCount: UInt64 = 0
  var backpressureDropCount: UInt64 = 0
  var lastEnqueuedAt: ContinuousClock.Instant?
  var lastPresentedAt: ContinuousClock.Instant?
  /// PTS handed to the display layer by the most recently delivered sample.
  /// Seconds keep qualification telemetry `Sendable`; this is not scheduling
  /// state and is never fed back into the renderer.
  var lastPresentedSampleTimeSeconds: Double?
  /// Playback generation that produced `lastPresentedSampleTimeSeconds`.
  /// Cleared at every generation boundary so a new media session never
  /// inherits the previous session's delivered PTS.
  var lastPresentedSamplePlaybackGeneration: UInt64?
  var latestPlaybackGeneration: UInt64?
  var latestVoutGeneration: UInt64?
  var voutTransitionCount: UInt64 = 0
  var status: PixelBufferRendererTelemetryStatus = .idle
  /// Timestamp of the newest sample the layer still holds from a synchronous
  /// submission. Cleared by a flush, since nothing queued then precedes the
  /// next sample.
  var lastSubmittedSampleTime: CMTime?
  /// When the layer first refused a synchronous submission in the current
  /// unbroken run of refusals.
  var notReadySince: ContinuousClock.Instant?
  /// Flushes issued because a sample was dated before the one queued ahead of
  /// it, or because the layer accepted nothing for the stall interval.
  var timelineFlushCount: UInt64 = 0
  var stallFlushCount: UInt64 = 0

  mutating func beginPlaybackGeneration(_ generation: UInt64) {
    pending = nil
    lastSubmittedSampleTime = nil
    notReadySince = nil
    flushRecoveryRetryCount = 0
    flushRecoveryGeneration = nil
    latestPlaybackGeneration = generation
    latestVoutGeneration = nil
    lastPresentedSampleTimeSeconds = nil
    lastPresentedSamplePlaybackGeneration = nil
    status = .idle
  }
}

enum PixelBufferRendererTelemetryStatus: Sendable, Equatable {
  case idle
  case rendering
  case backpressured
  case recovering
  case failed
}

struct PixelBufferRendererTelemetrySnapshot: Sendable, Equatable {
  let playbackGeneration: UInt64?
  let voutGeneration: UInt64?
  let decodedFrameCount: UInt64
  let lastDecodedFrameMediaTimeSeconds: Double?
  let decodedContentChangeCount: UInt64
  let lastDecodedContentFingerprint: UInt64?
  let renderGeneration: UInt64
  let presentationCopyRequired: Bool
  let presentationCopyFrameCount: UInt64
  let presentationCopyFailureCount: UInt64
  let displayLayerFlushRequestCount: UInt64
  let decodePoolAllocationFailureCount: UInt64
  let lastDecodePoolAllocationStatus: CVReturn?
  let renderPoolAllocationFailureCount: UInt64
  let lastRenderPoolAllocationStatus: CVReturn?
  let vmemLockAttemptCount: UInt64
  let vmemLockSuccessCount: UInt64
  let vmemPoolUnavailableCount: UInt64
  let vmemBaseAddressLockFailureCount: UInt64
  let vmemPendingInstallFailureCount: UInt64
  let vmemUnlockCallbackCount: UInt64
  let vmemDisplayCallbackCount: UInt64
  let vmemDisplayConsumeFailureCount: UInt64
  let enqueuedFrameCount: UInt64
  let presentedFrameCount: UInt64
  let droppedFrameCount: UInt64
  let voutTransitionCount: UInt64
  let flushCount: UInt64
  let backpressureDropCount: UInt64
  let replacementCount: UInt64
  let flushRecoveryRetryCount: UInt64
  let flushRecoveryFailureCount: UInt64
  let lastDecodedAt: ContinuousClock.Instant?
  let lastEnqueuedAt: ContinuousClock.Instant?
  let lastPresentedAt: ContinuousClock.Instant?
  let lastPresentedSampleTimeSeconds: Double?
  let lastPresentedSamplePlaybackGeneration: UInt64?
  let status: PixelBufferRendererTelemetryStatus
}

struct PixelBufferEnqueueSnapshot: Equatable {
  let pendingCount: Int
  let isDrainScheduled: Bool
  let scheduledDrainCount: UInt64
  let drainedSampleCount: UInt64
  let replacementCount: UInt64
  let flushRecoveryRetryCount: UInt64
  let flushRecoveryFailureCount: UInt64

  /// The recovery counters default to zero so assertions that predate flush
  /// recovery keep reading as "no recovery happened" without restating it.
  init(
    pendingCount: Int,
    isDrainScheduled: Bool,
    scheduledDrainCount: UInt64,
    drainedSampleCount: UInt64,
    replacementCount: UInt64,
    flushRecoveryRetryCount: UInt64 = 0,
    flushRecoveryFailureCount: UInt64 = 0
  ) {
    self.pendingCount = pendingCount
    self.isDrainScheduled = isDrainScheduled
    self.scheduledDrainCount = scheduledDrainCount
    self.drainedSampleCount = drainedSampleCount
    self.replacementCount = replacementCount
    self.flushRecoveryRetryCount = flushRecoveryRetryCount
    self.flushRecoveryFailureCount = flushRecoveryFailureCount
  }
}

/// What the drain loop should do after offering a sample to the layer.
enum PixelBufferSampleDisposition: Equatable {
  /// Delivered, superseded, stale, or dropped — the loop continues.
  case handled
  /// Retained for a later attempt; the loop must stop and re-drain after the
  /// retry delay, keeping ownership of the drain.
  case deferred
}

private enum PixelBufferDeferredRegistration {
  case rejected
  case installed(shouldSchedule: Bool)
  case needsSerializedVoutTransition
}

private enum PixelBufferDisplayRecoveryDecision: Equatable {
  case usable
  case flushRequired
  case permanentlyFailed
}

/// Injectable display-layer operations make queue saturation, backpressure,
/// flush, and delivery ordering deterministic in tests.
struct PixelBufferDisplayLayerAPI: @unchecked Sendable {
  let status: (AVSampleBufferDisplayLayer) -> AVQueuedSampleBufferRenderingStatus
  let requiresFlush: (AVSampleBufferDisplayLayer) -> Bool
  let flush: (AVSampleBufferDisplayLayer) -> Void
  let isReadyForMoreMediaData: (AVSampleBufferDisplayLayer) -> Bool
  let enqueue: (AVSampleBufferDisplayLayer, CMSampleBuffer) -> Void

  static var live: Self {
    Self(
      status: { $0.sampleBufferRenderer.status },
      requiresFlush: { $0.sampleBufferRenderer.requiresFlushToResumeDecoding },
      flush: { $0.sampleBufferRenderer.flush() },
      isReadyForMoreMediaData: { $0.sampleBufferRenderer.isReadyForMoreMediaData },
      enqueue: { $0.sampleBufferRenderer.enqueue($1) }
    )
  }
}

extension PixelBufferRenderer {
  func canEnqueueFrame(
    generation: UInt64,
    on layer: AVSampleBufferDisplayLayer,
    playbackGeneration: UInt64? = nil,
    voutGeneration: UInt64? = nil
  ) -> Bool {
    withOutputSubmissionSerialization {
      let acceptsRendererIdentity = state.withLock { state in
        state.renderGeneration == generation
          && state.displayLayer.layer === layer
          && playbackGeneration.map { $0 == (state.playbackGeneration ?? 0) } != false
      }
      guard acceptsRendererIdentity else { return false }
      return enqueueState.withLock { state in
        voutGeneration.map { $0 == state.latestVoutGeneration } != false
      }
    }
  }

  /// Replaces the one pending frame with the newest frame. At most one drain
  /// closure exists; it captures only the renderer, so a suspended queue owns
  /// O(1) samples regardless of decode rate or suspension duration.
  func enqueue(
    _ sample: CMSampleBuffer,
    generation: UInt64,
    on layer: AVSampleBufferDisplayLayer,
    playbackGeneration: UInt64 = 0,
    voutGeneration: UInt64 = 0
  ) {
    let pending = EnqueuedSampleBuffer(
      layer: layer,
      sample: sample,
      generation: generation,
      playbackGeneration: playbackGeneration,
      voutGeneration: voutGeneration
    )
    // Same-vout producers can replace the bounded slot while a slow output
    // call is in flight. A monotonic vout transition is rarer and must share
    // the final-output gate so a retired drain cannot cross the publication.
    let registration: PixelBufferDeferredRegistration = switch installDeferredSample(pending, allowingVoutTransition: false) {
    case .needsSerializedVoutTransition:
      withOutputSubmissionSerialization {
        installDeferredSample(pending, allowingVoutTransition: true)
      }
    case let result:
      result
    }

    guard case .installed(let shouldSchedule) = registration, shouldSchedule else { return }
    enqueueQueue.async { [self] in
      drainPendingSamples()
    }
  }

  /// Submits one exact frame before returning. Unlike ``enqueue``, this path
  /// never schedules, retains, retries or defers the sample. `true` therefore
  /// means the final display-layer enqueue closure was invoked synchronously.
  func enqueueSynchronously(
    _ sample: CMSampleBuffer,
    generation: UInt64,
    on layer: AVSampleBufferDisplayLayer,
    playbackGeneration: UInt64,
    voutGeneration: UInt64
  ) -> Bool {
    let pending = EnqueuedSampleBuffer(
      layer: layer,
      sample: sample,
      generation: generation,
      playbackGeneration: playbackGeneration,
      voutGeneration: voutGeneration
    )

    return withOutputSubmissionSerialization {
      guard acceptsRendererIdentity(pending) else { return false }
      let accepted = enqueueState.withLock { state -> Bool in
        guard registerIncomingSample(pending, state: &state) else { return false }
        // This exact synchronous frame supersedes any queued or retained
        // predecessor. Keep an existing drain gate owned: when that closure
        // runs it will observe the empty slot and release the gate.
        if state.pending != nil {
          state.replacementCount &+= 1
          state.pending = nil
        }
        state.flushRecoveryRetryCount = 0
        state.flushRecoveryGeneration = nil
        return true
      }
      guard accepted else { return false }

      let recoveryDecision = displayRecoveryDecision(for: layer)
      if recoveryDecision == .permanentlyFailed {
        recordPermanentDisplayFailure()
        return false
      }
      if recoveryDecision == .flushRequired {
        guard acceptsFullIdentity(pending) else { return false }
        displayLayerAPI.flush(layer)
        guard acceptsFullIdentity(pending) else { return false }
        enqueueState.withLock {
          $0.flushCount &+= 1
          $0.status = .recovering
          $0.lastSubmittedSampleTime = nil
        }
      }

      // The layer presents in timestamp order, and every sample is dated with
      // the control timebase's time as it is submitted. When that timebase is
      // moved back (a skip, a seek, a resynchronisation) a sample still queued
      // from before the move is suddenly dated in the future and holds every
      // later one until the timebase catches up: a frozen picture for the
      // whole distance, with audio running. This sample being dated before
      // its predecessor is that move, seen from here; drop what is queued so
      // it is the next one shown.
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
      let precedesQueuedSample = enqueueState.withLock { state -> Bool in
        guard
          presentationTime.isNumeric,
          let last = state.lastSubmittedSampleTime
        else { return false }
        return CMTimeCompare(presentationTime, last) < 0
      }
      if precedesQueuedSample {
        guard acceptsFullIdentity(pending) else { return false }
        displayLayerAPI.flush(layer)
        guard acceptsFullIdentity(pending) else { return false }
        enqueueState.withLock {
          $0.flushCount &+= 1
          $0.timelineFlushCount &+= 1
          $0.lastSubmittedSampleTime = nil
        }
      }

      if !displayLayerAPI.isReadyForMoreMediaData(layer) {
        guard acceptsFullIdentity(pending) else { return false }
        // Refusing a frame now and then is ordinary backpressure. Refusing
        // every frame for this long while the decoder keeps producing means
        // the queue is held by something that will not clear on its own, and
        // nothing else on this path would ever flush it.
        let now = currentInstant()
        let stalled = enqueueState.withLock { state -> Bool in
          state.backpressureDropCount &+= 1
          state.status = .backpressured
          guard let since = state.notReadySince else {
            state.notReadySince = now
            return false
          }
          guard since.duration(to: now) >= stallFlushInterval else { return false }
          // One flush per interval, however many frames arrive meanwhile.
          state.notReadySince = now
          return true
        }
        guard stalled else { return false }
        displayLayerAPI.flush(layer)
        guard acceptsFullIdentity(pending) else { return false }
        enqueueState.withLock {
          $0.flushCount &+= 1
          $0.stallFlushCount &+= 1
          $0.lastSubmittedSampleTime = nil
        }
        guard displayLayerAPI.isReadyForMoreMediaData(layer) else { return false }
      }
      guard acceptsFullIdentity(pending) else { return false }

      // No renderer mutex is held across this potentially reentrant framework
      // operation. Re-entry remains in the recursive submission domain and
      // can mutate lifecycle state without a self-deadlock.
      displayLayerAPI.enqueue(layer, sample)
      recordDeliveredSample(pending)
      enqueueState.withLock {
        $0.notReadySince = nil
        $0.lastSubmittedSampleTime = presentationTime.isNumeric ? presentationTime : nil
      }
      return true
    }
  }

  private func registerIncomingSample(
    _ pending: EnqueuedSampleBuffer,
    state: inout PixelBufferEnqueueState
  ) -> Bool {
    if
      let latestPlaybackGeneration = state.latestPlaybackGeneration,
      latestPlaybackGeneration != pending.playbackGeneration {
      return false
    }
    // Vout generations are issued monotonically. Once a successor appears,
    // a delayed callback from a retired vout can never regress the identity.
    if let latest = state.latestVoutGeneration, pending.voutGeneration < latest {
      return false
    }
    state.enqueuedFrameCount &+= 1
    state.lastEnqueuedAt = .now
    state.latestPlaybackGeneration = pending.playbackGeneration
    if state.latestVoutGeneration != pending.voutGeneration {
      state.voutTransitionCount &+= 1
      state.latestVoutGeneration = pending.voutGeneration
    }
    return true
  }

  private func installDeferredSample(
    _ pending: EnqueuedSampleBuffer,
    allowingVoutTransition: Bool
  ) -> PixelBufferDeferredRegistration {
    enqueueState.withLock { state in
      if
        let latestPlaybackGeneration = state.latestPlaybackGeneration,
        latestPlaybackGeneration != pending.playbackGeneration {
        return .rejected
      }
      if let latest = state.latestVoutGeneration, pending.voutGeneration < latest {
        return .rejected
      }
      if state.latestVoutGeneration != pending.voutGeneration, !allowingVoutTransition {
        return .needsSerializedVoutTransition
      }
      guard registerIncomingSample(pending, state: &state) else { return .rejected }
      if state.pending != nil {
        state.replacementCount &+= 1
      }
      state.pending = pending
      guard !state.isDrainScheduled else {
        return .installed(shouldSchedule: false)
      }
      state.isDrainScheduled = true
      state.scheduledDrainCount &+= 1
      return .installed(shouldSchedule: true)
    }
  }

  private func acceptsRendererIdentity(_ pending: EnqueuedSampleBuffer) -> Bool {
    state.withLock { state in
      state.renderGeneration == pending.generation
        && state.displayLayer.layer === pending.layer
        && (state.playbackGeneration ?? 0) == pending.playbackGeneration
    }
  }

  private func acceptsFullIdentity(_ pending: EnqueuedSampleBuffer) -> Bool {
    guard acceptsRendererIdentity(pending) else { return false }
    return enqueueState.withLock {
      $0.latestPlaybackGeneration == pending.playbackGeneration
        && $0.latestVoutGeneration == pending.voutGeneration
    }
  }

  var enqueueSnapshotForTesting: PixelBufferEnqueueSnapshot {
    enqueueState.withLock {
      PixelBufferEnqueueSnapshot(
        pendingCount: $0.pending == nil ? 0 : 1,
        isDrainScheduled: $0.isDrainScheduled,
        scheduledDrainCount: $0.scheduledDrainCount,
        drainedSampleCount: $0.drainedSampleCount,
        replacementCount: $0.replacementCount,
        flushRecoveryRetryCount: $0.flushRecoveryRetryCount,
        flushRecoveryFailureCount: $0.flushRecoveryFailureCount
      )
    }
  }

  var telemetrySnapshot: PixelBufferRendererTelemetrySnapshot {
    let decoded = state.withLock {
      (
        frameCount: $0.decodedFrameCount,
        mediaTimeSeconds: $0.lastDecodedFrameMediaTimeSeconds,
        lastAt: $0.lastDecodedAt,
        contentChangeCount: $0.decodedContentChangeCount,
        contentFingerprint: $0.lastDecodedContentFingerprint,
        renderGeneration: $0.renderGeneration,
        presentationCopyRequired: $0.presentationCopyRequired,
        presentationCopyFrameCount: $0.presentationCopyFrameCount,
        presentationCopyFailureCount: $0.presentationCopyFailureCount,
        flushRequestCount: $0.displayLayerFlushRequestCount,
        decodePoolFailureCount: $0.decodePoolAllocationFailureCount,
        decodePoolStatus: $0.lastDecodePoolAllocationStatus,
        renderPoolFailureCount: $0.renderPoolAllocationFailureCount,
        renderPoolStatus: $0.lastRenderPoolAllocationStatus,
        lockAttemptCount: $0.vmemLockAttemptCount,
        lockSuccessCount: $0.vmemLockSuccessCount,
        poolUnavailableCount: $0.vmemPoolUnavailableCount,
        baseAddressLockFailureCount: $0.vmemBaseAddressLockFailureCount,
        pendingInstallFailureCount: $0.vmemPendingInstallFailureCount,
        unlockCallbackCount: $0.vmemUnlockCallbackCount,
        displayCallbackCount: $0.vmemDisplayCallbackCount,
        displayConsumeFailureCount: $0.vmemDisplayConsumeFailureCount
      )
    }
    return enqueueState.withLock {
      PixelBufferRendererTelemetrySnapshot(
        playbackGeneration: $0.latestPlaybackGeneration,
        voutGeneration: $0.latestVoutGeneration,
        decodedFrameCount: decoded.frameCount,
        lastDecodedFrameMediaTimeSeconds: decoded.mediaTimeSeconds,
        decodedContentChangeCount: decoded.contentChangeCount,
        lastDecodedContentFingerprint: decoded.contentFingerprint,
        renderGeneration: decoded.renderGeneration,
        presentationCopyRequired: decoded.presentationCopyRequired,
        presentationCopyFrameCount: decoded.presentationCopyFrameCount,
        presentationCopyFailureCount: decoded.presentationCopyFailureCount,
        displayLayerFlushRequestCount: decoded.flushRequestCount,
        decodePoolAllocationFailureCount: decoded.decodePoolFailureCount,
        lastDecodePoolAllocationStatus: decoded.decodePoolStatus,
        renderPoolAllocationFailureCount: decoded.renderPoolFailureCount,
        lastRenderPoolAllocationStatus: decoded.renderPoolStatus,
        vmemLockAttemptCount: decoded.lockAttemptCount,
        vmemLockSuccessCount: decoded.lockSuccessCount,
        vmemPoolUnavailableCount: decoded.poolUnavailableCount,
        vmemBaseAddressLockFailureCount: decoded.baseAddressLockFailureCount,
        vmemPendingInstallFailureCount: decoded.pendingInstallFailureCount,
        vmemUnlockCallbackCount: decoded.unlockCallbackCount,
        vmemDisplayCallbackCount: decoded.displayCallbackCount,
        vmemDisplayConsumeFailureCount: decoded.displayConsumeFailureCount,
        enqueuedFrameCount: $0.enqueuedFrameCount,
        presentedFrameCount: $0.presentedFrameCount,
        droppedFrameCount: $0.replacementCount &+ $0.backpressureDropCount,
        voutTransitionCount: $0.voutTransitionCount,
        flushCount: $0.flushCount,
        backpressureDropCount: $0.backpressureDropCount,
        replacementCount: $0.replacementCount,
        flushRecoveryRetryCount: $0.flushRecoveryTotalRetryCount,
        flushRecoveryFailureCount: $0.flushRecoveryFailureCount,
        lastDecodedAt: decoded.lastAt,
        lastEnqueuedAt: $0.lastEnqueuedAt,
        lastPresentedAt: $0.lastPresentedAt,
        lastPresentedSampleTimeSeconds: $0.lastPresentedSampleTimeSeconds,
        lastPresentedSamplePlaybackGeneration: $0.lastPresentedSamplePlaybackGeneration,
        status: $0.status
      )
    }
  }

  /// How many times a single frame is re-offered after a flush before the
  /// renderer is treated as unrecoverable for that frame.
  static var maxFlushRecoveryRetries: UInt64 {
    10
  }

  private func drainPendingSamples() {
    while let pending = takePendingSampleOrFinishDrain() {
      switch processPendingSample(pending) {
      case .handled:
        continue
      case .deferred:
        // `isDrainScheduled` deliberately stays set: this drain still owns the
        // slot, so producers keep replacing the pending frame rather than
        // scheduling a competing drain.
        enqueueQueue.asyncAfter(deadline: .now() + flushRecoveryRetryDelay) { [self] in
          drainPendingSamples()
        }
        return
      }
    }
  }

  /// Clearing `isDrainScheduled` and observing an empty slot happen under the
  /// same mutex used by producers. A producer therefore either populates the
  /// slot before this check or observes the cleared flag and schedules the
  /// successor drain; there is no lost-wakeup window.
  private func takePendingSampleOrFinishDrain() -> EnqueuedSampleBuffer? {
    withOutputSubmissionSerialization {
      enqueueState.withLock { state in
        guard let pending = state.pending else {
          state.isDrainScheduled = false
          return nil
        }
        state.pending = nil
        state.drainedSampleCount &+= 1
        return pending
      }
    }
  }

  private func processPendingSample(
    _ pending: EnqueuedSampleBuffer
  )
    -> PixelBufferSampleDisposition {
    withOutputSubmissionSerialization {
      guard
        canEnqueueFrame(
          generation: pending.generation,
          on: pending.layer,
          playbackGeneration: pending.playbackGeneration,
          voutGeneration: pending.voutGeneration
        )
      else {
        return endFlushRecovery()
      }

      let recoveryDecision = displayRecoveryDecision(for: pending.layer)
      if recoveryDecision == .permanentlyFailed {
        recordPermanentDisplayFailure()
        return .handled
      }
      let shouldFlush = recoveryDecision == .flushRequired
      if shouldFlush {
        guard
          canEnqueueFrame(
            generation: pending.generation,
            on: pending.layer,
            playbackGeneration: pending.playbackGeneration,
            voutGeneration: pending.voutGeneration
          )
        else {
          return endFlushRecovery()
        }
        displayLayerAPI.flush(pending.layer)
        enqueueState.withLock {
          $0.flushCount &+= 1
          $0.status = .recovering
        }
      }

      guard displayLayerAPI.isReadyForMoreMediaData(pending.layer) else {
        // Recovery is sticky once entered. The flush above clears
        // `requiresFlushToResumeDecoding`, so a re-offer of the same frame sees
        // `shouldFlush == false` and would otherwise fall into the backpressure
        // drop below — losing the frame on the very first retry, which is the
        // bug this is meant to fix.
        let isRecovering = enqueueState.withLock {
          $0.flushRecoveryRetryCount > 0 && $0.flushRecoveryGeneration == pending.generation
        }
        // Plain backpressure keeps dropping: the decoder is still producing, so
        // a successor frame is already on its way and the newest one wins.
        guard shouldFlush || isRecovering else {
          enqueueState.withLock {
            $0.backpressureDropCount &+= 1
            $0.status = .backpressured
          }
          return .handled
        }
        // Flush recovery has no such guarantee. A paused seek, a final frame or
        // a foreground repaint may have no successor at all, so the frame that
        // triggered the flush is the only thing that can repaint the display —
        // dropping it here is what leaves PiP black with audio still running.
        return retainForFlushRecovery(pending)
      }

      guard acceptsFullIdentity(pending) else {
        return endFlushRecovery()
      }
      // Identity mutations are serialized by the recursive submission gate,
      // so the framework call needs no renderer mutex. A synchronous re-entry
      // can safely mutate lifecycle state.
      displayLayerAPI.enqueue(pending.layer, pending.sample)
      recordDeliveredSample(pending)
      return .handled
    }
  }

  private func recordDeliveredSample(_ pending: EnqueuedSampleBuffer) {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(pending.sample)
    enqueueState.withLock {
      guard
        $0.latestPlaybackGeneration == pending.playbackGeneration,
        $0.latestVoutGeneration == pending.voutGeneration
      else { return }
      $0.flushRecoveryRetryCount = 0
      $0.flushRecoveryGeneration = nil
      $0.presentedFrameCount &+= 1
      $0.lastPresentedAt = .now
      $0.lastPresentedSampleTimeSeconds = presentationTime.isNumeric
        ? presentationTime.seconds
        : nil
      $0.lastPresentedSamplePlaybackGeneration = pending.playbackGeneration
      $0.status = .rendering
    }
  }

  /// AVFoundation distinguishes decoder-resource revocation from a permanent
  /// renderer failure with `requiresFlushToResumeDecoding`. Flushing every
  /// `.failed` renderer erases that distinction and can turn an exact frame
  /// step into a false success after an unrecoverable output error.
  private func displayRecoveryDecision(
    for layer: AVSampleBufferDisplayLayer
  ) -> PixelBufferDisplayRecoveryDecision {
    let status = displayLayerAPI.status(layer)
    if displayLayerAPI.requiresFlush(layer) {
      return .flushRequired
    }
    return status == .failed ? .permanentlyFailed : .usable
  }

  private func recordPermanentDisplayFailure() {
    enqueueState.withLock { state in
      state.flushRecoveryRetryCount = 0
      state.flushRecoveryGeneration = nil
      if state.status != .failed {
        state.flushRecoveryFailureCount &+= 1
      }
      state.status = .failed
    }
  }

  /// Clears any in-progress recovery and drops the sample.
  ///
  /// Called when a frame is rejected as stale. Leaving the retry count set
  /// would make the *next* generation's plain backpressure read as "recovery
  /// in progress", quietly retaining frames on a path that is documented to
  /// drop them.
  private func endFlushRecovery() -> PixelBufferSampleDisposition {
    enqueueState.withLock {
      $0.flushRecoveryRetryCount = 0
      $0.flushRecoveryGeneration = nil
    }
    return .handled
  }

  /// Puts a post-flush frame back in the slot so a later attempt can deliver
  /// it, within a bounded budget.
  private func retainForFlushRecovery(
    _ pending: EnqueuedSampleBuffer
  )
    -> PixelBufferSampleDisposition {
    // Re-checked because the flush above released the state lock: a
    // replacement or teardown in that window must not resurrect this frame.
    guard
      canEnqueueFrame(
        generation: pending.generation,
        on: pending.layer,
        playbackGeneration: pending.playbackGeneration,
        voutGeneration: pending.voutGeneration
      )
    else {
      return endFlushRecovery()
    }

    return enqueueState.withLock { state in
      guard state.latestVoutGeneration == pending.voutGeneration else {
        state.flushRecoveryRetryCount = 0
        state.flushRecoveryGeneration = nil
        return .handled
      }
      // A newer frame already claimed the slot. It supersedes this one, and
      // the drain loop picks it up on the next iteration.
      guard state.pending == nil else {
        state.flushRecoveryRetryCount = 0
        state.flushRecoveryGeneration = nil
        return .handled
      }
      // The budget belongs to one frame's generation, so a replacement starts
      // over rather than inheriting whatever the previous media had spent.
      if state.flushRecoveryGeneration != pending.generation {
        state.flushRecoveryGeneration = pending.generation
        state.flushRecoveryRetryCount = 0
      }
      guard state.flushRecoveryRetryCount < Self.maxFlushRecoveryRetries else {
        // Bounded, and observable: the renderer never became ready, so the
        // frame is dropped rather than retried forever.
        state.flushRecoveryRetryCount = 0
        state.flushRecoveryGeneration = nil
        state.flushRecoveryFailureCount &+= 1
        state.status = .failed
        return .handled
      }
      state.flushRecoveryRetryCount &+= 1
      state.flushRecoveryTotalRetryCount &+= 1
      state.status = .recovering
      state.pending = pending
      return .deferred
    }
  }
}
#endif
