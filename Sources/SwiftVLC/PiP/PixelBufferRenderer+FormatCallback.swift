#if os(iOS) || os(macOS)
import CLibVLC
import CoreVideo
import Foundation
import Synchronization

/// Compatibility callback for released libVLC binaries. Its ABI exposes only
/// delivery dimensions, so it cannot prove nonzero crop offsets or residual
/// pixel aspect ratio. Patched binaries use ``pixelBufferFormatCallbackEx``.
func pixelBufferFormatCallback(
  opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  chroma: UnsafeMutablePointer<CChar>?,
  width: UnsafeMutablePointer<UInt32>?,
  height: UnsafeMutablePointer<UInt32>?,
  pitches: UnsafeMutablePointer<UInt32>?,
  lines: UnsafeMutablePointer<UInt32>?
) -> UInt32 {
  guard
    let width,
    let height
  else { return 0 }
  let geometry = PixelBufferSourceGeometry(
    fullFrameWidth: width.pointee,
    height: height.pointee
  )
  return configurePixelBufferFormat(
    opaque: opaque,
    chroma: chroma,
    sourceGeometry: geometry,
    deliveryWidth: width.pointee,
    deliveryHeight: height.pointee,
    pitches: pitches,
    lines: lines
  )
}

/// Geometry-aware callback used by the patched pinned libVLC. It copies the
/// single C geometry snapshot immediately, chooses an exact square-pixel
/// output, and rejects formats that cannot be normalized without approximation.
func pixelBufferFormatCallbackEx(
  opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  chroma: UnsafeMutablePointer<CChar>?,
  sourceGeometry: UnsafePointer<swiftvlc_video_format_geometry_t>?,
  outputWidth: UnsafeMutablePointer<UInt32>?,
  outputHeight: UnsafeMutablePointer<UInt32>?,
  pitches: UnsafeMutablePointer<UInt32>?,
  lines: UnsafeMutablePointer<UInt32>?
) -> UInt32 {
  guard
    let sourceGeometry,
    let outputWidth,
    let outputHeight
  else { return 0 }

  let geometry = PixelBufferSourceGeometry(sourceGeometry.pointee)
  guard let delivery = geometry.squarePixelDeliveryDimensions else { return 0 }
  outputWidth.pointee = delivery.width
  outputHeight.pointee = delivery.height

  return configurePixelBufferFormat(
    opaque: opaque,
    chroma: chroma,
    sourceGeometry: geometry,
    deliveryWidth: delivery.width,
    deliveryHeight: delivery.height,
    pitches: pitches,
    lines: lines
  )
}

private func configurePixelBufferFormat(
  opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  chroma: UnsafeMutablePointer<CChar>?,
  sourceGeometry: PixelBufferSourceGeometry,
  deliveryWidth: UInt32,
  deliveryHeight: UInt32,
  pitches: UnsafeMutablePointer<UInt32>?,
  lines: UnsafeMutablePointer<UInt32>?
) -> UInt32 {
  guard
    let opaque,
    let chroma,
    let pitches,
    let lines,
    sourceGeometry.isValid,
    deliveryWidth > 0,
    deliveryHeight > 0,
    let handleOpaque = opaque.pointee,
    let handleContext = pixelBufferHandleCallbackContext(from: handleOpaque)
  else { return 0 }

  let width = Int(deliveryWidth)
  let height = Int(deliveryHeight)

  // BGRA makes the vmem converter physically crop, orient and square-pixel
  // normalize into the exact one-plane Core Video surface requested above.
  let bgra: (CChar, CChar, CChar, CChar) = (0x42, 0x47, 0x52, 0x41)
  chroma[0] = bgra.0
  chroma[1] = bgra.1
  chroma[2] = bgra.2
  chroma[3] = bgra.3

  let poolAttributes: [String: Any] = [
    kCVPixelBufferPoolMinimumBufferCountKey as String:
      pixelBufferRendererPoolMinimumBufferCount(width: width, height: height)
  ]
  let pixelBufferAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
  ]

  var newPool: CVPixelBufferPool?
  let status = CVPixelBufferPoolCreate(
    kCFAllocatorDefault,
    poolAttributes as CFDictionary,
    pixelBufferAttributes as CFDictionary,
    &newPool
  )
  guard status == kCVReturnSuccess, let pool = newPool else { return 0 }

  let testAllocation = pixelBufferRendererAllocatePixelBuffer(
    from: pool,
    width: width,
    height: height
  )
  guard
    testAllocation.status == kCVReturnSuccess,
    let testBuffer = testAllocation.buffer
  else { return 0 }
  let actualPitch = CVPixelBufferGetBytesPerRow(testBuffer)
  guard actualPitch <= Int(UInt32.max) else { return 0 }

  pitches.pointee = UInt32(actualPitch)
  lines.pointee = deliveryHeight

  let decodeRenderer = PixelBufferRenderer()
  decodeRenderer.state.withLock {
    $0.pool = pool
    $0.width = width
    $0.height = height
  }
  guard
    let voutContext = handleContext.makeVoutContext(
      handleOpaque: handleOpaque,
      decodeRenderer: decodeRenderer,
      sourceGeometry: sourceGeometry
    )
  else { return 0 }

  opaque.pointee = Unmanaged.passRetained(voutContext).toOpaque()
  return pixelBufferRendererFormatSuccessCount
}
#endif
