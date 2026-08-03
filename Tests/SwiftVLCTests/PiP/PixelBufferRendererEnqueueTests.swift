#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import CoreVideo
import CustomDump
import Foundation
import Synchronization
import Testing

extension Integration {
  struct PixelBufferRendererEnqueueTests {
    @Test
    func `Blocked queue retains only the latest pending frame`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-blocked")
      let blocker = QueueBlocker(queue: queue)
      defer { blocker.release() }
      #expect(blocker.waitUntilStarted() == .success)

      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe()
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      var weakBuffers: [WeakPixelBuffer] = []
      for index in 0..<100 {
        try weakBuffers.append(
          submitFrame(
            index: index,
            renderer: renderer,
            generation: generation,
            layer: layer
          )
        )
      }

      expectNoDifference(
        renderer.enqueueSnapshotForTesting,
        PixelBufferEnqueueSnapshot(
          pendingCount: 1,
          isDrainScheduled: true,
          scheduledDrainCount: 1,
          drainedSampleCount: 0,
          replacementCount: 99
        )
      )
      #expect(weakBuffers.dropLast().allSatisfy { $0.value == nil })
      #expect(weakBuffers.last?.value != nil)

      blocker.release()
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)

      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [99])
      expectNoDifference(
        renderer.enqueueSnapshotForTesting,
        PixelBufferEnqueueSnapshot(
          pendingCount: 0,
          isDrainScheduled: false,
          scheduledDrainCount: 1,
          drainedSampleCount: 1,
          replacementCount: 99
        )
      )
      #expect(weakBuffers.allSatisfy { $0.value == nil })
    }

    @Test
    func `Slow delivery retains one processing frame and one latest pending frame`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-slow")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(blockFirstEnqueue: true)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      var weakBuffers = try [
        submitFrame(
          index: 0,
          renderer: renderer,
          generation: generation,
          layer: layer
        )
      ]
      #expect(probe.waitForEnqueueEntry() == .success)

      for index in 1..<100 {
        try weakBuffers.append(
          submitFrame(
            index: index,
            renderer: renderer,
            generation: generation,
            layer: layer
          )
        )
      }

      expectNoDifference(
        renderer.enqueueSnapshotForTesting,
        PixelBufferEnqueueSnapshot(
          pendingCount: 1,
          isDrainScheduled: true,
          scheduledDrainCount: 1,
          drainedSampleCount: 1,
          replacementCount: 98
        )
      )
      #expect(weakBuffers[0].value != nil)
      #expect(weakBuffers[1..<99].allSatisfy { $0.value == nil })
      #expect(weakBuffers[99].value != nil)

      probe.releaseBlockedEnqueue()
      #expect(probe.waitForDelivery() == .success)
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)

      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [0, 99])
      expectNoDifference(
        renderer.enqueueSnapshotForTesting,
        PixelBufferEnqueueSnapshot(
          pendingCount: 0,
          isDrainScheduled: false,
          scheduledDrainCount: 1,
          drainedSampleCount: 2,
          replacementCount: 98
        )
      )
      #expect(weakBuffers.allSatisfy { $0.value == nil })
    }

    @Test
    func `Stale generation and layer drop clears the gate for a successor`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-stale")
      let blocker = QueueBlocker(queue: queue)
      defer { blocker.release() }
      #expect(blocker.waitUntilStarted() == .success)

      let oldLayer = AVSampleBufferDisplayLayer()
      let newLayer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe()
      let renderer = PixelBufferRenderer(
        displayLayer: oldLayer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      let staleGeneration = renderer.state.withLock { $0.renderGeneration }
      _ = try submitFrame(
        index: 1,
        renderer: renderer,
        generation: staleGeneration,
        layer: oldLayer
      )

      renderer.setRenderSize(CMVideoDimensions(width: 16, height: 9))
      renderer.setDisplayLayer(newLayer)
      let currentGeneration = renderer.state.withLock { $0.renderGeneration }

      blocker.release()
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [])
      #expect(!renderer.enqueueSnapshotForTesting.isDrainScheduled)

      _ = try submitFrame(
        index: 2,
        renderer: renderer,
        generation: currentGeneration,
        layer: newLayer
      )
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)

      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [2])
      expectNoDifference(
        renderer.enqueueSnapshotForTesting,
        PixelBufferEnqueueSnapshot(
          pendingCount: 0,
          isDrainScheduled: false,
          scheduledDrainCount: 2,
          drainedSampleCount: 2,
          replacementCount: 0
        )
      )
    }

    @Test
    func `Backpressure drop clears the gate and a later ready frame delivers`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-backpressure")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(isReady: false)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(
        index: 1,
        renderer: renderer,
        generation: generation,
        layer: layer
      )
      #expect(probe.waitForReadinessCheck() == .success)
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [])
      #expect(!renderer.enqueueSnapshotForTesting.isDrainScheduled)

      probe.setReady(true)
      _ = try submitFrame(
        index: 2,
        renderer: renderer,
        generation: generation,
        layer: layer
      )
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)

      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [2])
      expectNoDifference(renderer.enqueueSnapshotForTesting.scheduledDrainCount, UInt64(2))
    }

    @Test
    func `Required flush does not strand the pending gate`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-flush")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(requiresFlush: true)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(
        index: 7,
        renderer: renderer,
        generation: generation,
        layer: layer
      )
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)

      expectNoDifference(probe.snapshot.flushCount, 1)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [7])
      #expect(!renderer.enqueueSnapshotForTesting.isDrainScheduled)
    }

    /// The bug this issue is about: a flush leaves the renderer briefly not
    /// ready, and the frame that triggered the flush used to be dropped. A
    /// paused seek, a final frame or a foreground repaint has no successor,
    /// so nothing ever repaints and PiP stays black with audio still running.
    /// The frame must be retained and delivered when readiness returns —
    /// *without* another frame being supplied.
    @Test
    func `A flush-triggering frame is retained and delivered without a successor`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-flush-retain")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(requiresFlush: true, isReady: false)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api,
        flushRecoveryRetryDelay: .milliseconds(1)
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(index: 11, renderer: renderer, generation: generation, layer: layer)
      #expect(probe.waitForReadinessCheck() == .success)

      // Readiness returns on its own; no further frame is submitted.
      probe.setReady(true)

      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [11])
      #expect(renderer.enqueueSnapshotForTesting.flushRecoveryFailureCount == 0)
    }

    /// Recovery is bounded: a renderer that never becomes ready must give up
    /// and say so, rather than re-offering the same frame forever.
    @Test
    func `Flush recovery gives up explicitly when readiness never returns`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-flush-giveup")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(requiresFlush: true, isReady: false)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api,
        flushRecoveryRetryDelay: .milliseconds(1)
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(index: 12, renderer: renderer, generation: generation, layer: layer)

      let deadline = ContinuousClock.now + .seconds(5)
      while renderer.enqueueSnapshotForTesting.flushRecoveryFailureCount == 0 {
        if ContinuousClock.now >= deadline {
          Issue.record("flush recovery never terminated")
          break
        }
        _ = waitUntilIdle(queue)
      }

      #expect(waitUntilIdle(queue) == .success)
      let snapshot = renderer.enqueueSnapshotForTesting
      #expect(snapshot.flushRecoveryFailureCount == 1)
      #expect(snapshot.pendingCount == 0, "the frame was left stranded in the slot")
      #expect(!snapshot.isDrainScheduled, "the drain gate was left owned after giving up")
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [])
    }

    /// A newer frame supersedes one being retried — the freshest content
    /// wins, which is what keeps live playback behaving as before.
    @Test
    func `A newer frame supersedes one awaiting flush recovery`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-flush-supersede")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(requiresFlush: true, isReady: false)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api,
        flushRecoveryRetryDelay: .milliseconds(5)
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(index: 20, renderer: renderer, generation: generation, layer: layer)
      #expect(probe.waitForReadinessCheck() == .success)

      _ = try submitFrame(index: 21, renderer: renderer, generation: generation, layer: layer)
      probe.setReady(true)

      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [21])
    }

    /// A frame retained across a flush must not survive a generation bump:
    /// replacing the media or the vout invalidates it, and displaying it
    /// afterwards would show the previous media.
    @Test
    func `A retained frame is discarded when the generation moves on`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-flush-generation")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(requiresFlush: true, isReady: false)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api,
        flushRecoveryRetryDelay: .milliseconds(5)
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(index: 30, renderer: renderer, generation: generation, layer: layer)
      #expect(probe.waitForReadinessCheck() == .success)

      // The media/vout moves on while the frame is awaiting recovery.
      renderer.state.withLock { $0.advanceRenderGeneration() }
      probe.setReady(true)

      // The retained frame is re-offered after the retry delay, so settle
      // before asserting rather than racing the scheduled drain.
      #expect(waitForDrainToSettle(renderer, queue: queue) == .success)
      expectNoDifference(
        probe.snapshot.enqueuedPresentationValues,
        [],
        "a stale-generation frame reached the display after replacement"
      )
      #expect(
        renderer.enqueueSnapshotForTesting.flushRecoveryRetryCount == 0,
        "recovery state survived the generation bump"
      )
    }

    /// Discarding a retained frame must also end its recovery. Otherwise the
    /// next generation's *plain backpressure* reads as "recovery in progress"
    /// and starts retaining frames on a path documented to drop them.
    @Test
    func `A discarded recovery does not leak into the next generation's backpressure`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-flush-leak")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe(requiresFlush: true, isReady: false)
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api,
        flushRecoveryRetryDelay: .milliseconds(5)
      )
      let generation = renderer.state.withLock { $0.renderGeneration }

      // Enter recovery, then invalidate the frame that is being retried.
      _ = try submitFrame(index: 40, renderer: renderer, generation: generation, layer: layer)
      #expect(probe.waitForReadinessCheck() == .success)
      renderer.state.withLock { $0.advanceRenderGeneration() }
      #expect(waitForDrainToSettle(renderer, queue: queue) == .success)

      // A fresh generation hitting plain backpressure must drop and clear the
      // gate, exactly as it would have without any prior recovery.
      let nextGeneration = renderer.state.withLock { $0.renderGeneration }
      probe.setRequiresFlush(false)
      _ = try submitFrame(index: 41, renderer: renderer, generation: nextGeneration, layer: layer)
      #expect(probe.waitForReadinessCheck() == .success)
      #expect(waitForDrainToSettle(renderer, queue: queue) == .success)

      let snapshot = renderer.enqueueSnapshotForTesting
      #expect(snapshot.pendingCount == 0, "a backpressured frame was retained after recovery leaked")
      #expect(!snapshot.isDrainScheduled, "the drain gate stayed owned by leaked recovery state")
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [])
    }

    @Test
    func `A stale playback generation cannot install or deliver a frame`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-playback-generation")
      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe()
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      renderer.beginPlaybackGeneration(2)
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(
        index: 1,
        renderer: renderer,
        generation: generation,
        layer: layer,
        playbackGeneration: 1
      )
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [])
      #expect(renderer.telemetrySnapshot.enqueuedFrameCount == 0)

      _ = try submitFrame(
        index: 2,
        renderer: renderer,
        generation: generation,
        layer: layer,
        playbackGeneration: 2
      )
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [2])
    }

    @Test
    func `Retired vout callbacks cannot regress identity or replace successor frames`() throws {
      let queue = DispatchQueue(label: "org.swiftvlc.tests.enqueue-vout-generation")
      let blocker = QueueBlocker(queue: queue)
      defer { blocker.release() }
      #expect(blocker.waitUntilStarted() == .success)

      let layer = AVSampleBufferDisplayLayer()
      let probe = DisplayLayerProbe()
      let renderer = PixelBufferRenderer(
        displayLayer: layer,
        enqueueQueue: queue,
        displayLayerAPI: probe.api
      )
      renderer.beginPlaybackGeneration(3)
      let generation = renderer.state.withLock { $0.renderGeneration }

      _ = try submitFrame(
        index: 1,
        renderer: renderer,
        generation: generation,
        layer: layer,
        playbackGeneration: 3,
        voutGeneration: 1
      )
      _ = try submitFrame(
        index: 2,
        renderer: renderer,
        generation: generation,
        layer: layer,
        playbackGeneration: 3,
        voutGeneration: 2
      )
      _ = try submitFrame(
        index: 3,
        renderer: renderer,
        generation: generation,
        layer: layer,
        playbackGeneration: 3,
        voutGeneration: 1
      )
      _ = try submitFrame(
        index: 4,
        renderer: renderer,
        generation: generation,
        layer: layer,
        playbackGeneration: 3,
        voutGeneration: 2
      )

      blocker.release()
      #expect(probe.waitForDelivery() == .success)
      #expect(waitUntilIdle(queue) == .success)
      expectNoDifference(probe.snapshot.enqueuedPresentationValues, [4])
      let telemetry = renderer.telemetrySnapshot
      #expect(telemetry.voutGeneration == 2)
      #expect(telemetry.voutTransitionCount == 2)
      #expect(telemetry.enqueuedFrameCount == 3)
    }

    private func submitFrame(
      index: Int,
      renderer: PixelBufferRenderer,
      generation: UInt64,
      layer: AVSampleBufferDisplayLayer,
      playbackGeneration: UInt64 = 0,
      voutGeneration: UInt64 = 0
    )
      throws -> WeakPixelBuffer {
      try autoreleasepool {
        let buffer = try makePixelBuffer()
        let weakBuffer = WeakPixelBuffer(buffer)
        let description = try makeFormatDescription(for: buffer)
        var timing = CMSampleTimingInfo(
          duration: CMTime(value: 1, timescale: 30),
          presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 1),
          decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: buffer,
          formatDescription: description,
          sampleTiming: &timing,
          sampleBufferOut: &sample
        )
        expectNoDifference(status, noErr)
        try renderer.enqueue(
          #require(sample),
          generation: generation,
          on: layer,
          playbackGeneration: playbackGeneration,
          voutGeneration: voutGeneration
        )
        return weakBuffer
      }
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        2,
        2,
        kCVPixelFormatType_32BGRA,
        nil,
        &buffer
      )
      expectNoDifference(status, kCVReturnSuccess)
      return try #require(buffer)
    }

    private func makeFormatDescription(
      for buffer: CVPixelBuffer
    )
      throws -> CMVideoFormatDescription {
      var description: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescriptionOut: &description
      )
      expectNoDifference(status, noErr)
      return try #require(description)
    }

    /// Waits until no drain is scheduled and the slot is empty.
    ///
    /// `waitUntilIdle` only flushes work already queued; a flush-recovery
    /// re-offer is scheduled with `asyncAfter`, so it can still be pending
    /// when a plain barrier returns.
    private func waitForDrainToSettle(
      _ renderer: PixelBufferRenderer,
      queue: DispatchQueue
    )
      -> DispatchTimeoutResult {
      let deadline = ContinuousClock.now + .seconds(5)
      while ContinuousClock.now < deadline {
        _ = waitUntilIdle(queue)
        let snapshot = renderer.enqueueSnapshotForTesting
        if !snapshot.isDrainScheduled, snapshot.pendingCount == 0 {
          return .success
        }
      }
      return .timedOut
    }

    private func waitUntilIdle(_ queue: DispatchQueue) -> DispatchTimeoutResult {
      let completed = DispatchSemaphore(value: 0)
      queue.async { completed.signal() }
      return completed.wait(timeout: .now() + 5)
    }
  }
}

private final class WeakPixelBuffer {
  weak var value: CVPixelBuffer?

  init(_ value: CVPixelBuffer) {
    self.value = value
  }
}

private final class QueueBlocker: @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private let wasReleased = Mutex(false)

  init(queue: DispatchQueue) {
    queue.async { [started, releaseSemaphore] in
      started.signal()
      releaseSemaphore.wait()
    }
  }

  func waitUntilStarted() -> DispatchTimeoutResult {
    started.wait(timeout: .now() + 5)
  }

  func release() {
    let shouldSignal = wasReleased.withLock { wasReleased -> Bool in
      guard !wasReleased else { return false }
      wasReleased = true
      return true
    }
    if shouldSignal {
      releaseSemaphore.signal()
    }
  }
}

private final class DisplayLayerProbe: @unchecked Sendable {
  struct Snapshot: Equatable {
    let flushCount: Int
    let enqueuedPresentationValues: [CMTimeValue]
  }

  private struct State: @unchecked Sendable {
    var status: AVQueuedSampleBufferRenderingStatus = .rendering
    var requiresFlush: Bool
    var isReady: Bool
    var shouldBlockNextEnqueue: Bool
    var flushCount = 0
    var enqueuedPresentationValues: [CMTimeValue] = []
  }

  private let state: Mutex<State>
  private let enqueueEntry = DispatchSemaphore(value: 0)
  private let releaseEnqueue = DispatchSemaphore(value: 0)
  private let delivery = DispatchSemaphore(value: 0)
  private let readinessCheck = DispatchSemaphore(value: 0)

  init(
    requiresFlush: Bool = false,
    isReady: Bool = true,
    blockFirstEnqueue: Bool = false
  ) {
    state = Mutex(
      State(
        requiresFlush: requiresFlush,
        isReady: isReady,
        shouldBlockNextEnqueue: blockFirstEnqueue
      )
    )
  }

  var api: PixelBufferDisplayLayerAPI {
    PixelBufferDisplayLayerAPI(
      status: { [self] _ in state.withLock { $0.status } },
      requiresFlush: { [self] _ in state.withLock { $0.requiresFlush } },
      flush: { [self] _ in
        state.withLock {
          $0.flushCount += 1
          $0.requiresFlush = false
        }
      },
      isReadyForMoreMediaData: { [self] _ in
        let result = state.withLock { $0.isReady }
        readinessCheck.signal()
        return result
      },
      enqueue: { [self] _, sample in
        let shouldBlock = state.withLock { state -> Bool in
          guard state.shouldBlockNextEnqueue else { return false }
          state.shouldBlockNextEnqueue = false
          return true
        }
        enqueueEntry.signal()
        if shouldBlock {
          releaseEnqueue.wait()
        }
        state.withLock {
          $0.enqueuedPresentationValues.append(
            CMSampleBufferGetPresentationTimeStamp(sample).value
          )
        }
        delivery.signal()
      }
    )
  }

  var snapshot: Snapshot {
    state.withLock {
      Snapshot(
        flushCount: $0.flushCount,
        enqueuedPresentationValues: $0.enqueuedPresentationValues
      )
    }
  }

  func setReady(_ isReady: Bool) {
    state.withLock { $0.isReady = isReady }
  }

  func setRequiresFlush(_ requiresFlush: Bool) {
    state.withLock { $0.requiresFlush = requiresFlush }
  }

  func waitForEnqueueEntry() -> DispatchTimeoutResult {
    enqueueEntry.wait(timeout: .now() + 5)
  }

  func releaseBlockedEnqueue() {
    releaseEnqueue.signal()
  }

  func waitForDelivery() -> DispatchTimeoutResult {
    delivery.wait(timeout: .now() + 5)
  }

  func waitForReadinessCheck() -> DispatchTimeoutResult {
    readinessCheck.wait(timeout: .now() + 5)
  }
}
#endif
