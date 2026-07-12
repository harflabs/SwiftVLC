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
}

struct PixelBufferEnqueueSnapshot: Equatable {
  let pendingCount: Int
  let isDrainScheduled: Bool
  let scheduledDrainCount: UInt64
  let drainedSampleCount: UInt64
  let replacementCount: UInt64
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
        replacementCount: $0.replacementCount
      )
    }
  }

  private func drainPendingSamples() {
    while let pending = takePendingSampleOrFinishDrain() {
      processPendingSample(pending)
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

  private func processPendingSample(_ pending: EnqueuedSampleBuffer) {
    guard canEnqueueFrame(generation: pending.generation, on: pending.layer) else { return }

    let shouldFlush = displayLayerAPI.status(pending.layer) == .failed
      || displayLayerAPI.requiresFlush(pending.layer)
    if shouldFlush {
      guard canEnqueueFrame(generation: pending.generation, on: pending.layer) else { return }
      displayLayerAPI.flush(pending.layer)
    }

    guard displayLayerAPI.isReadyForMoreMediaData(pending.layer) else { return }

    // The final validation and enqueue share one state-lock linearization
    // point. A generation/layer mutation either happens first and rejects this
    // sample, or happens after this enqueue; stale work cannot cross it.
    state.withLock { state in
      guard
        state.renderGeneration == pending.generation,
        state.displayLayer.layer === pending.layer
      else { return }
      displayLayerAPI.enqueue(pending.layer, pending.sample)
    }
  }
}
#endif
