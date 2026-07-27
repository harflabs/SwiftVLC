#if os(iOS) || os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Carries media objects onto the serial enqueue queue. Pending ownership is
/// held by one replaceable slot, never by one closure per decoded frame.
struct EnqueuedSampleBuffer: @unchecked Sendable {
  let layer: AVSampleBufferDisplayLayer
  let sample: CMSampleBuffer
  let generation: UInt64
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
  /// Times flush recovery exhausted its budget and dropped the frame. A
  /// non-zero value is the explicit terminal failure the display never
  /// repainted from.
  var flushRecoveryFailureCount: UInt64 = 0
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
  func canEnqueueFrame(generation: UInt64, on layer: AVSampleBufferDisplayLayer) -> Bool {
    state.withLock {
      $0.renderGeneration == generation && $0.displayLayer.layer === layer
    }
  }

  /// Replaces the one pending frame with the newest frame. At most one drain
  /// closure exists; it captures only the renderer, so a suspended queue owns
  /// O(1) samples regardless of decode rate or suspension duration.
  func enqueue(
    _ sample: CMSampleBuffer,
    generation: UInt64,
    on layer: AVSampleBufferDisplayLayer
  ) {
    let pending = EnqueuedSampleBuffer(
      layer: layer,
      sample: sample,
      generation: generation
    )
    let shouldSchedule = enqueueState.withLock { state -> Bool in
      if state.pending != nil {
        state.replacementCount &+= 1
      }
      state.pending = pending
      guard !state.isDrainScheduled else { return false }
      state.isDrainScheduled = true
      state.scheduledDrainCount &+= 1
      return true
    }

    guard shouldSchedule else { return }
    enqueueQueue.async { [self] in
      drainPendingSamples()
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

  private func processPendingSample(
    _ pending: EnqueuedSampleBuffer
  )
    -> PixelBufferSampleDisposition {
    guard canEnqueueFrame(generation: pending.generation, on: pending.layer) else {
      return endFlushRecovery()
    }

    let shouldFlush = displayLayerAPI.status(pending.layer) == .failed
      || displayLayerAPI.requiresFlush(pending.layer)
    if shouldFlush {
      guard canEnqueueFrame(generation: pending.generation, on: pending.layer) else {
        return endFlushRecovery()
      }
      displayLayerAPI.flush(pending.layer)
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
      guard shouldFlush || isRecovering else { return .handled }
      // Flush recovery has no such guarantee. A paused seek, a final frame or
      // a foreground repaint may have no successor at all, so the frame that
      // triggered the flush is the only thing that can repaint the display —
      // dropping it here is what leaves PiP black with audio still running.
      return retainForFlushRecovery(pending)
    }

    // The final validation and enqueue share one state-lock linearization
    // point. A generation/layer mutation either happens first and rejects this
    // sample, or happens after this enqueue; stale work cannot cross it.
    let delivered = state.withLock { state -> Bool in
      guard
        state.renderGeneration == pending.generation,
        state.displayLayer.layer === pending.layer
      else { return false }
      displayLayerAPI.enqueue(pending.layer, pending.sample)
      return true
    }
    if delivered {
      enqueueState.withLock {
        $0.flushRecoveryRetryCount = 0
        $0.flushRecoveryGeneration = nil
      }
    }
    return .handled
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
    guard canEnqueueFrame(generation: pending.generation, on: pending.layer) else {
      return endFlushRecovery()
    }

    return enqueueState.withLock { state in
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
        return .handled
      }
      state.flushRecoveryRetryCount &+= 1
      state.pending = pending
      return .deferred
    }
  }
}
#endif
