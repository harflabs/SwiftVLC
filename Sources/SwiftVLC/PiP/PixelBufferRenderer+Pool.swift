#if os(iOS) || os(macOS)
import CoreVideo
import Foundation

/// Pinned VLC treats the format callback's return as a success/failure count:
/// zero rejects the vout and any positive value accepts it. SwiftVLC proves one
/// buffer allocation while negotiating the pool, so report that one allocation
/// instead of claiming decode headroom the pinned vmem module does not use.
let pixelBufferRendererFormatSuccessCount: UInt32 = 1

/// Upper bound for the recycled pool floor on small frames. This affects only
/// Core Video's resident reuse policy; it is independent of the format
/// callback's success count above.
let pixelBufferRendererPoolMaximumBufferCount = 12

/// Soft cap on the bytes a single `CVPixelBufferPool` keeps resident as
/// its recycled floor. This governs how many *returned* buffers the pool
/// retains; pinned vmem does not derive decoder headroom from setup's count.
/// Without it, a 4K BGRA pool with a 12-buffer floor pins ~380 MiB even
/// when idle. ~96 MiB keeps HD/SD generously buffered while letting 4K
/// drain its recycled buffers.
let pixelBufferRendererPoolMaximumResidentBytes = 96 * 1024 * 1024

private final class PixelBufferPoolAuxiliaryAttributes: @unchecked Sendable {
  let dictionary: CFDictionary

  init(allocationThreshold: Int) {
    dictionary = [
      kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold
    ] as CFDictionary
  }
}

/// Thresholds are constrained to 3...12. Build each immutable auxiliary
/// dictionary once so the per-frame allocation guard does not itself allocate
/// a Swift dictionary on the decode hot path.
private let pixelBufferRendererPoolAuxiliaryAttributes = (3...12).map {
  PixelBufferPoolAuxiliaryAttributes(allocationThreshold: $0)
}

/// Byte-budgeted resident floor for a BGRA pool of the given dimensions.
/// Frames for which a three-buffer floor would exceed the complete resident
/// budget use a floor of one; smaller frames keep the 3...12 range.
func pixelBufferRendererPoolMinimumBufferCount(width: Int, height: Int) -> Int {
  let (pixelCount, pixelCountOverflow) = max(1, width).multipliedReportingOverflow(
    by: max(1, height)
  )
  guard !pixelCountOverflow else { return 1 }
  let (bytesPerBuffer, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
  guard !byteCountOverflow else { return 1 }

  let threeBufferThreshold = pixelBufferRendererPoolMaximumResidentBytes / 3
  if bytesPerBuffer > threeBufferThreshold {
    return 1
  }

  let budgeted = pixelBufferRendererPoolMaximumResidentBytes / bytesPerBuffer
  return max(3, min(pixelBufferRendererPoolMaximumBufferCount, budgeted))
}

/// Hard upper bound for buffers allocated from one pool. Three is the minimum
/// safe pipeline shape (one being produced, one pending, one processing), and
/// the threshold never undercuts the configured recycled pool floor.
func pixelBufferRendererPoolAllocationThreshold(width: Int, height: Int) -> Int {
  max(3, pixelBufferRendererPoolMinimumBufferCount(width: width, height: height))
}

/// Allocates with an explicit threshold so a stalled display layer cannot turn
/// either the decode pool or resize pool into an unbounded memory queue.
func pixelBufferRendererAllocatePixelBuffer(
  from pool: CVPixelBufferPool,
  width: Int,
  height: Int
) -> (status: CVReturn, buffer: CVPixelBuffer?) {
  let threshold = pixelBufferRendererPoolAllocationThreshold(width: width, height: height)
  let auxiliaryAttributes = pixelBufferRendererPoolAuxiliaryAttributes[threshold - 3]
  var buffer: CVPixelBuffer?
  let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
    kCFAllocatorDefault,
    pool,
    auxiliaryAttributes.dictionary,
    &buffer
  )
  return (status, buffer)
}
#endif
