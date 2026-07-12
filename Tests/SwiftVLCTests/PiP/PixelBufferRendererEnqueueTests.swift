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

    private func submitFrame(
      index: Int,
      renderer: PixelBufferRenderer,
      generation: UInt64,
      layer: AVSampleBufferDisplayLayer
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
          on: layer
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
