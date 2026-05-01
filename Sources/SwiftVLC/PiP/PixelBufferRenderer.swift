#if os(iOS) || os(macOS)
import AVFoundation
import CLibVLC
import CoreImage
import CoreMedia
import CoreVideo
import Synchronization

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
    var pool: CVPixelBufferPool?
    var width: Int = 0
    var height: Int = 0
    var renderSize: CMVideoDimensions?
    var renderPool: CVPixelBufferPool?
    var renderPoolWidth: Int = 0
    var renderPoolHeight: Int = 0
    var renderGeneration: UInt64 = 0
    /// The display layer is held inside a class box rather than as a
    /// direct `weak var` on the struct. `Mutex` stores `State` in raw
    /// managed memory and any `withLock { $0 }` read produces a struct
    /// copy; bit-copying a `__weak` slot side-steps the ObjC runtime's
    /// weak-reference table and surfaces as "unregister unknown __weak
    /// variable" warnings at teardown. The box gives the weak a single
    /// stable home the runtime can track across struct copies.
    let displayLayer: DisplayLayerBox
    var timebase: CMTimebase?

    init(displayLayer: AVSampleBufferDisplayLayer?) {
      self.displayLayer = DisplayLayerBox(displayLayer)
    }
  }

  let state: Mutex<State>
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  init(displayLayer: AVSampleBufferDisplayLayer) {
    state = Mutex(State(displayLayer: displayLayer))
  }

  func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer?) {
    state.withLock { $0.displayLayer.layer = layer }
  }

  func setTimebase(_ tb: CMTimebase?) {
    state.withLock { $0.timebase = tb }
  }

  func setRenderSize(_ size: CMVideoDimensions?) {
    state.withLock {
      guard $0.renderSize?.width != size?.width || $0.renderSize?.height != size?.height else {
        return
      }
      $0.renderSize = size
      $0.renderPool = nil
      $0.renderPoolWidth = 0
      $0.renderPoolHeight = 0
      $0.renderGeneration &+= 1
    }
  }

  func flushDisplayLayer() {
    let layer = state.withLock { $0.displayLayer.layer }
    DispatchQueue.main.async { [layer] in
      layer?.sampleBufferRenderer.flush()
    }
  }

  func outputPixelBuffer(from source: CVPixelBuffer) -> (buffer: CVPixelBuffer, generation: UInt64)? {
    let (target, generation) = state.withLock { ($0.renderSize, $0.renderGeneration) }
    guard
      let target,
      target.width > 0,
      target.height > 0
    else {
      return (source, generation)
    }

    let width = Int(target.width)
    let height = Int(target.height)
    if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height {
      return (source, generation)
    }

    guard let output = makeRenderPixelBuffer(width: width, height: height) else {
      return nil
    }

    let sourceWidth = CGFloat(CVPixelBufferGetWidth(source))
    let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
    let targetWidth = CGFloat(width)
    let targetHeight = CGFloat(height)
    guard sourceWidth > 0, sourceHeight > 0 else { return (source, generation) }

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

    ciContext.render(image, to: output, bounds: frame, colorSpace: colorSpace)
    return (output, generation)
  }

  func canEnqueueFrame(generation: UInt64, on layer: AVSampleBufferDisplayLayer) -> Bool {
    state.withLock {
      $0.renderGeneration == generation && $0.displayLayer.layer === layer
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
        kCVPixelBufferPoolMinimumBufferCountKey as String: 3
      ]

      var newPool: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        poolAttrs as CFDictionary,
        attrs as CFDictionary,
        &newPool
      )
      guard status == kCVReturnSuccess, let newPool else { return nil }

      state.renderPool = newPool
      state.renderPoolWidth = width
      state.renderPoolHeight = height
      return newPool
    }

    guard let pool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    guard status == kCVReturnSuccess else { return nil }
    return pixelBuffer
  }
}

/// Class wrapper around `weak var layer` so the ObjC weak-reference
/// table sees a single stable address regardless of how `State` is
/// copied in and out of the surrounding `Mutex`.
final class DisplayLayerBox: @unchecked Sendable {
  weak var layer: AVSampleBufferDisplayLayer?
  init(_ layer: AVSampleBufferDisplayLayer?) {
    self.layer = layer
  }
}

// MARK: - Free Function Callbacks

/// Format callback, invoked by libVLC when video format is negotiated.
/// Overrides chroma to BGRA and creates a `CVPixelBufferPool`.
func pixelBufferFormatCallback(
  opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  chroma: UnsafeMutablePointer<CChar>?,
  width: UnsafeMutablePointer<UInt32>?,
  height: UnsafeMutablePointer<UInt32>?,
  pitches: UnsafeMutablePointer<UInt32>?,
  lines: UnsafeMutablePointer<UInt32>?
) -> UInt32 {
  guard
    let opaque, let chroma, let width, let height,
    let pitches, let lines else { return 0 }

  // libVLC populates `*opaque` with the context we passed to
  // `libvlc_video_set_callbacks`. Guard against an unattached context.
  guard let rendererBox = opaque.pointee else { return 0 }
  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(rendererBox).takeUnretainedValue()

  let w = Int(width.pointee)
  let h = Int(height.pointee)

  // Force BGRA: native to iOS, no color space conversion needed.
  let bgra: (CChar, CChar, CChar, CChar) = (0x42, 0x47, 0x52, 0x41) // "BGRA"
  chroma[0] = bgra.0
  chroma[1] = bgra.1
  chroma[2] = bgra.2
  chroma[3] = bgra.3

  // Create CVPixelBufferPool
  let poolAttrs: [String: Any] = [
    kCVPixelBufferPoolMinimumBufferCountKey as String: 3
  ]
  let pixelBufferAttrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: w,
    kCVPixelBufferHeightKey as String: h,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
  ]

  var newPool: CVPixelBufferPool?
  let status = CVPixelBufferPoolCreate(
    kCFAllocatorDefault,
    poolAttrs as CFDictionary,
    pixelBufferAttrs as CFDictionary,
    &newPool
  )
  guard status == kCVReturnSuccess, let pool = newPool else { return 0 }

  // Get actual bytesPerRow from a real buffer so VLC pitch matches exactly
  var testBuffer: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &testBuffer)
  guard let tb = testBuffer else { return 0 }
  let actualPitch = CVPixelBufferGetBytesPerRow(tb)

  pitches.pointee = UInt32(actualPitch)
  lines.pointee = UInt32(h)

  renderer.state.withLock {
    $0.pool = pool
    $0.width = w
    $0.height = h
  }

  return 1 // number of picture buffers (1 plane for BGRA)
}

/// Lock callback. Dequeues a `CVPixelBuffer` from the pool for libVLC to write into.
func pixelBufferLockCallback(
  opaque: UnsafeMutableRawPointer?,
  planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> UnsafeMutableRawPointer? {
  guard let opaque, let planes else { return nil }

  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(opaque).takeUnretainedValue()

  let pool = renderer.state.withLock { $0.pool }

  guard let pool else { return nil }

  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
  guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

  CVPixelBufferLockBaseAddress(pb, [])
  planes[0] = CVPixelBufferGetBaseAddress(pb)

  let retained = Unmanaged.passRetained(pb as AnyObject)
  return retained.toOpaque()
}

/// Unlock callback. Unlocks the `CVPixelBuffer` base address.
func pixelBufferUnlockCallback(
  opaque _: UnsafeMutableRawPointer?,
  picture: UnsafeMutableRawPointer?,
  planes _: UnsafePointer<UnsafeMutableRawPointer?>?
) {
  guard let picture else { return }

  // `as!` (not `as?`): the compiler emits "conditional downcast will
  // always succeed" for CoreFoundation bridged types.
  let pb = Unmanaged<AnyObject>.fromOpaque(picture).takeUnretainedValue() as! CVPixelBuffer
  CVPixelBufferUnlockBaseAddress(pb, [])
}

/// Display callback. Wraps the `CVPixelBuffer` in a `CMSampleBuffer`
/// and enqueues it onto the `AVSampleBufferDisplayLayer`.
func pixelBufferDisplayCallback(
  opaque: UnsafeMutableRawPointer?,
  picture: UnsafeMutableRawPointer?
) {
  guard let opaque, let picture else { return }

  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(opaque).takeUnretainedValue()
  // `takeRetainedValue` balances the `passRetained` in `pixelBufferLockCallback`.
  let pb = Unmanaged<AnyObject>.fromOpaque(picture).takeRetainedValue() as! CVPixelBuffer

  guard let output = renderer.outputPixelBuffer(from: pb) else { return }
  let outputBuffer = output.buffer
  let renderGeneration = output.generation

  var formatDesc: CMVideoFormatDescription?
  let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
    allocator: kCFAllocatorDefault,
    imageBuffer: outputBuffer,
    formatDescriptionOut: &formatDesc
  )
  guard fmtStatus == noErr, let desc = formatDesc else { return }

  let (timebase, layer) = renderer.state.withLock { ($0.timebase, $0.displayLayer.layer) }

  guard let layer else { return }

  let pts: CMTime = if let timebase {
    CMTimebaseGetTime(timebase)
  } else {
    CMClockGetTime(CMClockGetHostTimeClock())
  }

  var timingInfo = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 30),
    presentationTimeStamp: pts,
    decodeTimeStamp: .invalid
  )

  var sampleBuffer: CMSampleBuffer?
  let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
    allocator: kCFAllocatorDefault,
    imageBuffer: outputBuffer,
    formatDescription: desc,
    sampleTiming: &timingInfo,
    sampleBufferOut: &sampleBuffer
  )
  guard sbStatus == noErr, let sb = sampleBuffer else { return }

  // CMSampleBuffer is a CF type that lacks Sendable conformance but is thread-safe for read access
  nonisolated(unsafe) let sample = sb
  DispatchQueue.main.async { [layer, renderer] in
    guard renderer.canEnqueueFrame(generation: renderGeneration, on: layer) else { return }
    let renderer = layer.sampleBufferRenderer
    if renderer.status == .failed {
      renderer.flush()
    }
    renderer.enqueue(sample)
  }
}

/// Cleanup callback. Releases the pixel buffer pool.
func pixelBufferCleanupCallback(opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }

  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(opaque).takeUnretainedValue()

  renderer.state.withLock {
    $0.pool = nil
    $0.renderPool = nil
    $0.renderPoolWidth = 0
    $0.renderPoolHeight = 0
    $0.renderGeneration &+= 1
  }
}

#endif
