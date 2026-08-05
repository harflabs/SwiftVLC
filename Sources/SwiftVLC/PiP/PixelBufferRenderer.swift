#if os(iOS) || os(macOS)
import AVFoundation
import CLibVLC
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization

/// Core Image objects shared by every scaled frame produced by one renderer.
/// Kept in a reference type so tests can verify identity reuse and `State`
/// copies never duplicate resource ownership.
final class PixelBufferScalingResources: @unchecked Sendable {
  let context = CIContext(options: [.cacheIntermediates: false])
  let colorSpace = CGColorSpaceCreateDeviceRGB()
}

/// Renders libVLC video frames into `CVPixelBuffer`s via vmem callbacks,
/// then enqueues them as `CMSampleBuffer`s onto an `AVSampleBufferDisplayLayer`.
///
/// Thread safety: all vmem callbacks run on libVLC's decode thread.
/// `Mutex<State>` protects shared state accessed from both the decode thread and main thread.
final class PixelBufferRenderer: Sendable {
  /// @unchecked because CF types (CVPixelBufferPool, CMTimebase) lack
  /// Sendable conformance. Thread safety is guaranteed by the enclosing
  /// Mutex.
  struct State: @unchecked Sendable {
    struct CachedFormatDescription: @unchecked Sendable {
      let generation: UInt64
      let description: CMVideoFormatDescription
    }

    var pool: CVPixelBufferPool?
    var width: Int = 0
    var height: Int = 0
    var renderSize: CMVideoDimensions?
    var renderPool: CVPixelBufferPool?
    var renderPoolWidth: Int = 0
    var renderPoolHeight: Int = 0
    /// Direct PiP must not hand libVLC's bounded decode buffers to AVKit.
    /// AVKit can retain those buffers across the PiP transition, starving
    /// vmem before another frame can be decoded. While this is true, frames
    /// are copied into the independently bounded presentation pool even when
    /// the requested render geometry matches the source.
    var presentationCopyRequired = false
    var presentationCopyFrameCount: UInt64 = 0
    var presentationCopyFailureCount: UInt64 = 0
    var measuredConversionCount: UInt64 = 0
    var measuredConversionNanoseconds: UInt64 = 0
    var maximumMeasuredConversionNanoseconds: UInt64 = 0
    var renderGeneration: UInt64 = 0
    var displayLayerFlushRequestCount: UInt64 = 0
    var decodePoolAllocationFailureCount: UInt64 = 0
    var lastDecodePoolAllocationStatus: CVReturn?
    var renderPoolAllocationFailureCount: UInt64 = 0
    var lastRenderPoolAllocationStatus: CVReturn?
    var vmemLockAttemptCount: UInt64 = 0
    var vmemLockSuccessCount: UInt64 = 0
    var vmemPoolUnavailableCount: UInt64 = 0
    var vmemBaseAddressLockFailureCount: UInt64 = 0
    var vmemPendingInstallFailureCount: UInt64 = 0
    var vmemUnlockCallbackCount: UInt64 = 0
    var vmemDisplayCallbackCount: UInt64 = 0
    var vmemDisplayConsumeFailureCount: UInt64 = 0
    var cachedFormatDescription: CachedFormatDescription?
    var formatDescriptionCreationCount: UInt64 = 0
    var scalingResources: PixelBufferScalingResources?
    /// The display layer is held inside a class box rather than as a
    /// direct `weak var` on the struct. `Mutex` stores `State` in raw
    /// managed memory and any `withLock { $0 }` read produces a struct
    /// copy; bit-copying a `__weak` slot side-steps the ObjC runtime's
    /// weak-reference table and surfaces as "unregister unknown __weak
    /// variable" warnings at teardown. The box gives the weak a single
    /// stable home the runtime can track across struct copies.
    let displayLayer: DisplayLayerBox
    var timebase: CMTimebase?
    var decodedFrameCount: UInt64 = 0
    var lastDecodedAt: ContinuousClock.Instant?
    /// Opt-in qualification probe. Disabled for normal clients so sampling
    /// decoded pixels adds no work to the production hot path.
    var contentFingerprintingEnabled = false
    var lastDecodedContentFingerprint: UInt64?
    var decodedContentChangeCount: UInt64 = 0
    var playbackGeneration: UInt64?

    init(displayLayer: AVSampleBufferDisplayLayer?) {
      self.displayLayer = DisplayLayerBox(displayLayer)
    }

    mutating func advanceRenderGeneration() {
      renderGeneration &+= 1
      cachedFormatDescription = nil
    }
  }

  let state: Mutex<State>
  /// Lock-free copy-isolation signal mirrored into the active callback handle.
  /// libVLC reads it for every decoded frame, so it must not require renderer
  /// or callback-context mutexes on the normal zero-copy path.
  let presentationCopyEnabled = Atomic<Bool>(false)
  /// Fast gate for qualification-only callback counters. The callback context
  /// mirrors this value so disabled production callbacks avoid entering the
  /// renderer and callback-context mutexes solely for telemetry.
  let contentDiagnosticsEnabled = Atomic<Bool>(false)
  let enqueueQueue: DispatchQueue
  let enqueueState = Mutex(PixelBufferEnqueueState())
  let displayLayerAPI: PixelBufferDisplayLayerAPI

  /// How long to wait before re-offering a frame the renderer was not ready
  /// for after a flush. Injectable so recovery tests do not sleep a real
  /// frame interval.
  let flushRecoveryRetryDelay: DispatchTimeInterval

  init(
    displayLayer: AVSampleBufferDisplayLayer? = nil,
    enqueueQueue: DispatchQueue? = nil,
    displayLayerAPI: PixelBufferDisplayLayerAPI = .live,
    flushRecoveryRetryDelay: DispatchTimeInterval = .milliseconds(16)
  ) {
    state = Mutex(State(displayLayer: displayLayer))
    self.enqueueQueue = enqueueQueue ?? DispatchQueue(
      label: "org.swiftvlc.pixel-buffer-renderer.enqueue"
    )
    self.displayLayerAPI = displayLayerAPI
    self.flushRecoveryRetryDelay = flushRecoveryRetryDelay
  }

  func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer?) {
    state.withLock { $0.displayLayer.layer = layer }
  }

  /// Starts a new media generation and makes every frame captured before the boundary stale.
  /// Counters stay cumulative for generation-local health deltas without resetting the hot path.
  func beginPlaybackGeneration(_ generation: UInt64) {
    let changed = state.withLock { state -> Bool in
      guard state.playbackGeneration != generation else { return false }
      state.playbackGeneration = generation
      state.advanceRenderGeneration()
      return true
    }
    guard changed else { return }
    enqueueState.withLock { $0.beginPlaybackGeneration(generation) }
    flushDisplayLayer()
  }

  func setTimebase(_ tb: CMTimebase?) {
    state.withLock { $0.timebase = tb }
  }

  func setContentFingerprintingEnabled(_ enabled: Bool) {
    if !enabled {
      contentDiagnosticsEnabled.store(false, ordering: .releasing)
    }
    state.withLock { state in
      state.contentFingerprintingEnabled = enabled
      state.lastDecodedContentFingerprint = nil
      state.decodedContentChangeCount = 0
      state.measuredConversionCount = 0
      state.measuredConversionNanoseconds = 0
      state.maximumMeasuredConversionNanoseconds = 0
    }
    if enabled {
      contentDiagnosticsEnabled.store(true, ordering: .releasing)
    }
  }

  /// Samples a fixed grid of BGRA pixels. This is deliberately not a full
  /// frame hash: qualification only needs to prove that decoded content keeps
  /// changing after backgrounding, and bounded sampling avoids turning the
  /// diagnostic into a material renderer workload.
  func recordContentFingerprintIfEnabled(of pixelBuffer: CVPixelBuffer) {
    guard contentDiagnosticsEnabled.load(ordering: .acquiring) else { return }
    guard let fingerprint = Self.sampledContentFingerprint(of: pixelBuffer) else { return }
    state.withLock { state in
      guard state.contentFingerprintingEnabled else { return }
      if
        let previous = state.lastDecodedContentFingerprint,
        previous != fingerprint {
        state.decodedContentChangeCount &+= 1
      }
      state.lastDecodedContentFingerprint = fingerprint
    }
  }

  static func sampledContentFingerprint(of pixelBuffer: CVPixelBuffer) -> UInt64? {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      return nil
    }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var fingerprint: UInt64 = 0xCBF2_9CE4_8422_2325
    func mix(_ byte: UInt8) {
      fingerprint ^= UInt64(byte)
      fingerprint &*= 0x100_0000_01B3
    }

    // Include geometry so equal prefixes from differently sized buffers never
    // compare as the same decoded frame.
    for shift in stride(from: 0, through: 56, by: 8) {
      mix(UInt8(truncatingIfNeeded: UInt64(width) >> UInt64(shift)))
      mix(UInt8(truncatingIfNeeded: UInt64(height) >> UInt64(shift)))
    }
    let columns = min(width, 16)
    let rows = min(height, 9)
    for row in 0..<rows {
      let y = rows == 1 ? 0 : row * (height - 1) / (rows - 1)
      for column in 0..<columns {
        let x = columns == 1 ? 0 : column * (width - 1) / (columns - 1)
        let offset = y * bytesPerRow + x * 4
        mix(bytes[offset])
        mix(bytes[offset + 1])
        mix(bytes[offset + 2])
        mix(bytes[offset + 3])
      }
    }
    return fingerprint
  }

  /// The vmem callback ABI exposes decoded pixels but not the duration of the
  /// individual source frame. libVLC's track ratio is nominal/average for
  /// variable-rate media (for example, a 24→60 fps fixture reports `42/1`), so
  /// converting that ratio to one duration fabricates timing. An invalid
  /// duration leaves scheduling to the presentation timestamp.
  static let sampleDuration: CMTime = .invalid

  /// Returns whether the target actually moved, so callers can skip work that
  /// is only warranted by a real change — a display-layer flush, in
  /// particular, which AVKit can otherwise be made to do for every redundant
  /// render-size callback.
  @discardableResult
  func setRenderSize(_ size: CMVideoDimensions?) -> Bool {
    state.withLock {
      guard $0.renderSize?.width != size?.width || $0.renderSize?.height != size?.height else {
        return false
      }
      $0.renderSize = size
      $0.renderPool = nil
      $0.renderPoolWidth = 0
      $0.renderPoolHeight = 0
      $0.advanceRenderGeneration()
      return true
    }
  }

  /// Isolates AVKit's presentation ownership from libVLC's decode pool.
  ///
  /// The copy is scoped to active PiP. Inline playback keeps the zero-copy
  /// path, and stopping PiP immediately restores it.
  func setPresentationCopyRequired(_ required: Bool) {
    presentationCopyEnabled.store(required, ordering: .releasing)
    state.withLock { $0.presentationCopyRequired = required }
  }

  func flushDisplayLayer() {
    let layer = state.withLock { state in
      state.displayLayerFlushRequestCount &+= 1
      return state.displayLayer.layer
    }
    DispatchQueue.main.async { [layer] in
      layer?.sampleBufferRenderer.flush()
    }
  }

  func outputPixelBuffer(from source: CVPixelBuffer) -> (buffer: CVPixelBuffer, generation: UInt64)? {
    let interval = Signposts.signposter.beginInterval("PixelBufferRenderer.outputPixelBuffer")
    defer { Signposts.signposter.endInterval("PixelBufferRenderer.outputPixelBuffer", interval) }
    let (target, generation, copyRequired) = state.withLock {
      ($0.renderSize, $0.renderGeneration, $0.presentationCopyRequired)
    }
    let sourcePixelWidth = CVPixelBufferGetWidth(source)
    let sourcePixelHeight = CVPixelBufferGetHeight(source)
    guard sourcePixelWidth > 0, sourcePixelHeight > 0 else { return (source, generation) }

    let width: Int
    let height: Int
    if let target, target.width > 0, target.height > 0 {
      width = Int(target.width)
      height = Int(target.height)
    } else if copyRequired {
      width = sourcePixelWidth
      height = sourcePixelHeight
    } else {
      return (source, generation)
    }

    if sourcePixelWidth == width, sourcePixelHeight == height, !copyRequired {
      return (source, generation)
    }

    // Qualification diagnostics opt into conversion timing. Normal clients
    // avoid even the monotonic-clock reads on this per-frame hot path.
    let conversionStarted = contentDiagnosticsEnabled.load(ordering: .acquiring)
      ? DispatchTime.now().uptimeNanoseconds
      : nil
    defer {
      if let conversionStarted {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- conversionStarted
        state.withLock { state in
          guard state.contentFingerprintingEnabled else { return }
          state.measuredConversionCount &+= 1
          state.measuredConversionNanoseconds &+= elapsed
          state.maximumMeasuredConversionNanoseconds = max(
            state.maximumMeasuredConversionNanoseconds,
            elapsed
          )
        }
      }
    }

    // libVLC invokes this on its decode thread, which has no run-loop-owned
    // autorelease pool. Core Image's Objective-C graph objects retain the
    // source pixel buffer; without a local pool, a completed conversion can
    // therefore keep the one transition-headroom buffer alive indefinitely.
    return autoreleasepool {
      guard let output = makeRenderPixelBuffer(width: width, height: height) else {
        return nil
      }

      let sourceWidth = CGFloat(sourcePixelWidth)
      let sourceHeight = CGFloat(sourcePixelHeight)
      let targetWidth = CGFloat(width)
      let targetHeight = CGFloat(height)
      let scale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
      let fittedWidth = sourceWidth * scale
      let fittedHeight = sourceHeight * scale
      let offsetX = (targetWidth - fittedWidth) / 2
      let offsetY = (targetHeight - fittedHeight) / 2

      let transform = CGAffineTransform(
        a: scale,
        b: 0,
        c: 0,
        d: scale,
        tx: offsetX,
        ty: offsetY
      )
      let frame = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
      let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        .cropped(to: frame)
      let image = CIImage(cvPixelBuffer: source)
        .transformed(by: transform)
        .composited(over: background)

      let resources = scalingResourcesForResize()
      if copyRequired {
        // `CIContext.render(_:to:bounds:colorSpace:)` may return after GPU work
        // has merely been scheduled. PiP's one-frame decode headroom cannot
        // make forward progress if Core Image still retains that source buffer,
        // so make completion of the ownership transfer explicit.
        do {
          let destination = CIRenderDestination(pixelBuffer: output)
          destination.colorSpace = resources.colorSpace
          let task = try resources.context.startTask(toRender: image, to: destination)
          _ = try task.waitUntilCompleted()
          state.withLock {
            if $0.contentFingerprintingEnabled {
              $0.presentationCopyFrameCount &+= 1
            }
          }
        } catch {
          state.withLock {
            if $0.contentFingerprintingEnabled {
              $0.presentationCopyFailureCount &+= 1
            }
          }
          return nil
        }
      } else {
        resources.context.render(
          image,
          to: output,
          bounds: frame,
          colorSpace: resources.colorSpace
        )
      }
      return (output, generation)
    }
  }

  private func scalingResourcesForResize() -> PixelBufferScalingResources {
    state.withLock { state in
      if let resources = state.scalingResources {
        return resources
      }
      let resources = PixelBufferScalingResources()
      state.scalingResources = resources
      return resources
    }
  }

  private func makeRenderPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    let pool = state.withLock { state -> CVPixelBufferPool? in
      if state.renderPoolWidth == width, state.renderPoolHeight == height, let pool = state.renderPool {
        return pool
      }

      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
      ]
      let poolAttrs: [String: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as String:
          pixelBufferRendererPoolMinimumBufferCount(width: width, height: height)
      ]

      var newPool: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        poolAttrs as CFDictionary,
        attrs as CFDictionary,
        &newPool
      )
      guard status == kCVReturnSuccess, let newPool else {
        state.renderPoolAllocationFailureCount &+= 1
        state.lastRenderPoolAllocationStatus = status
        return nil
      }

      state.renderPool = newPool
      state.renderPoolWidth = width
      state.renderPoolHeight = height
      return newPool
    }

    guard let pool else { return nil }
    let allocation = pixelBufferRendererAllocatePixelBuffer(
      from: pool,
      width: width,
      height: height
    )
    guard allocation.status == kCVReturnSuccess, let buffer = allocation.buffer else {
      state.withLock {
        $0.renderPoolAllocationFailureCount &+= 1
        $0.lastRenderPoolAllocationStatus = allocation.status
      }
      return nil
    }
    return buffer
  }
}

#endif
