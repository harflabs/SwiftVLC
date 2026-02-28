#if os(iOS) || os(macOS)
import AVFoundation
import CLibVLC
import CoreMedia
import CoreVideo
import Synchronization

/// Renders libVLC video frames into `CVPixelBuffer`s via vmem callbacks,
/// then enqueues them as `CMSampleBuffer`s onto an `AVSampleBufferDisplayLayer`.
///
/// Thread safety: all vmem callbacks run on libVLC's decode thread.
/// `Mutex<State>` protects shared state accessed from both the decode thread and main thread.
final class PixelBufferRenderer: Sendable {
  /// @unchecked because CF types (CVPixelBufferPool, CMTimebase) and
  /// AVSampleBufferDisplayLayer lack Sendable conformance. Thread safety
  /// is guaranteed by the enclosing Mutex.
  struct State: @unchecked Sendable {
    var pool: CVPixelBufferPool?
    var width: Int = 0
    var height: Int = 0
    weak var displayLayer: AVSampleBufferDisplayLayer?
    var timebase: CMTimebase?
  }

  let state: Mutex<State>

  init(displayLayer: AVSampleBufferDisplayLayer) {
    state = Mutex(State(displayLayer: displayLayer))
  }

  func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer?) {
    state.withLock { $0.displayLayer = layer }
  }

  func setTimebase(_ tb: CMTimebase?) {
    state.withLock { $0.timebase = tb }
  }
}

// MARK: - Free Function Callbacks

/// Format callback — called by libVLC when video format is negotiated.
/// Overrides chroma to BGRA, creates a `CVPixelBufferPool`.
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

  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(opaque.pointee!).takeUnretainedValue()

  let w = Int(width.pointee)
  let h = Int(height.pointee)

  // Force BGRA — native to iOS, no color space conversion needed
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

/// Lock callback — dequeues a `CVPixelBuffer` from the pool for libVLC to write into.
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

/// Unlock callback — unlocks the `CVPixelBuffer` base address.
func pixelBufferUnlockCallback(
  opaque _: UnsafeMutableRawPointer?,
  picture: UnsafeMutableRawPointer?,
  planes _: UnsafePointer<UnsafeMutableRawPointer?>?
) {
  guard let picture else { return }

  let pb = Unmanaged<AnyObject>.fromOpaque(picture).takeUnretainedValue() as! CVPixelBuffer
  CVPixelBufferUnlockBaseAddress(pb, [])
}

/// Display callback — wraps the `CVPixelBuffer` in a `CMSampleBuffer` and enqueues
/// it onto the `AVSampleBufferDisplayLayer`.
func pixelBufferDisplayCallback(
  opaque: UnsafeMutableRawPointer?,
  picture: UnsafeMutableRawPointer?
) {
  guard let opaque, let picture else { return }

  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(opaque).takeUnretainedValue()
  let pb = Unmanaged<AnyObject>.fromOpaque(picture).takeRetainedValue() as! CVPixelBuffer

  var formatDesc: CMVideoFormatDescription?
  let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
    allocator: kCFAllocatorDefault,
    imageBuffer: pb,
    formatDescriptionOut: &formatDesc
  )
  guard fmtStatus == noErr, let desc = formatDesc else { return }

  let (timebase, layer) = renderer.state.withLock { ($0.timebase, $0.displayLayer) }

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
    imageBuffer: pb,
    formatDescription: desc,
    sampleTiming: &timingInfo,
    sampleBufferOut: &sampleBuffer
  )
  guard sbStatus == noErr, let sb = sampleBuffer else { return }

  // CMSampleBuffer is a CF type that lacks Sendable conformance but is thread-safe for read access
  nonisolated(unsafe) let sample = sb
  DispatchQueue.main.async { [layer] in
    let renderer = layer.sampleBufferRenderer
    if renderer.status == .failed {
      renderer.flush()
    }
    renderer.enqueue(sample)
  }
}

/// Cleanup callback — releases the pixel buffer pool.
func pixelBufferCleanupCallback(opaque: UnsafeMutableRawPointer?) {
  guard let opaque else { return }

  let renderer = Unmanaged<PixelBufferRenderer>.fromOpaque(opaque).takeUnretainedValue()

  renderer.state.withLock { $0.pool = nil }
}

#endif
