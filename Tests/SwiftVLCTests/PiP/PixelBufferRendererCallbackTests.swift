#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import CoreVideo
import CustomDump
import Synchronization
import Testing

/// Exercises the vmem C callbacks directly with mocked inputs. Without a
/// live decoder we can't trigger them via the normal play path, but the
/// callbacks are plain free functions so we can invoke them with
/// hand-built parameters and verify the state transitions.
///
/// Covers format → lock → unlock → display → cleanup — the core pipeline
/// that moves decoded frames from libVLC into an
/// `AVSampleBufferDisplayLayer`.
extension Integration {
  struct PixelBufferRendererCallbackTests {
    /// Build the 4-tuple of buffers libVLC hands to the format callback.
    private struct FormatBuffers {
      var chroma: [CChar] = Array(repeating: 0, count: 4)
      var width: UInt32 = 320
      var height: UInt32 = 240
      var pitches: UInt32 = 0
      var lines: UInt32 = 0
    }

    private func makeRetainedContext(
      renderer: PixelBufferRenderer
    ) -> Unmanaged<PixelBufferRendererCallbackContext> {
      Unmanaged.passRetained(PixelBufferRendererCallbackContext(renderer: renderer))
    }

    /// Owns the handle-level callback retain plus every per-vout retain created
    /// by a successful format callback. Tests can close vouts in arbitrary
    /// order; any forgotten vout is still balanced before the handle retain.
    private final class CallbackLease {
      struct Vout {
        let opaque: UnsafeMutableRawPointer
        let context: PixelBufferRendererVoutCallbackContext
        let buffers: FormatBuffers
        let successCount: UInt32
      }

      let handleContext: PixelBufferRendererCallbackContext
      let handleOpaque: UnsafeMutableRawPointer
      private var openVoutOpaques: [UnsafeMutableRawPointer] = []

      init(displayRenderer: PixelBufferRenderer) {
        let handleContext = PixelBufferRendererCallbackContext(renderer: displayRenderer)
        self.handleContext = handleContext
        handleOpaque = Unmanaged.passRetained(handleContext).toOpaque()
      }

      deinit {
        for opaque in openVoutOpaques {
          pixelBufferCleanupCallback(opaque: opaque)
        }
        Unmanaged<PixelBufferRendererCallbackContext>.fromOpaque(handleOpaque).release()
      }

      func negotiate(width: UInt32, height: UInt32) throws -> Vout {
        var opaqueSlot: UnsafeMutableRawPointer? = handleOpaque
        var chroma = [CChar](repeating: 0, count: 4)
        var negotiatedWidth = width
        var negotiatedHeight = height
        var pitch: UInt32 = 0
        var lines: UInt32 = 0
        let result = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePointer in
          chroma.withUnsafeMutableBufferPointer { chromaBuffer in
            withUnsafeMutablePointer(to: &negotiatedWidth) { widthPointer in
              withUnsafeMutablePointer(to: &negotiatedHeight) { heightPointer in
                withUnsafeMutablePointer(to: &pitch) { pitchPointer in
                  withUnsafeMutablePointer(to: &lines) { linesPointer in
                    pixelBufferFormatCallback(
                      opaque: opaquePointer,
                      chroma: chromaBuffer.baseAddress,
                      width: widthPointer,
                      height: heightPointer,
                      pitches: pitchPointer,
                      lines: linesPointer
                    )
                  }
                }
              }
            }
          }
        }
        let voutOpaque = try #require(opaqueSlot)
        let voutContext = try #require(pixelBufferVoutCallbackContext(from: voutOpaque))
        openVoutOpaques.append(voutOpaque)
        return Vout(
          opaque: voutOpaque,
          context: voutContext,
          buffers: FormatBuffers(
            chroma: chroma,
            width: negotiatedWidth,
            height: negotiatedHeight,
            pitches: pitch,
            lines: lines
          ),
          successCount: result
        )
      }

      func close(_ vout: Vout) {
        guard let index = openVoutOpaques.firstIndex(of: vout.opaque) else { return }
        openVoutOpaques.remove(at: index)
        pixelBufferCleanupCallback(opaque: vout.opaque)
      }
    }

    private func makeBGRAImageBuffer(
      width: Int,
      height: Int,
      alpha: UInt8 = .max
    )
      throws -> CVPixelBuffer {
      var pixelBuffer: CVPixelBuffer?
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
      ]
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pixelBuffer
      )
      #expect(status == kCVReturnSuccess)
      let buffer = try #require(pixelBuffer)

      #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
      let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
      for row in 0..<height {
        var pixel = base.advanced(by: row * bytesPerRow)
        for column in 0..<width {
          pixel[0] = UInt8((column * 47) & 0xFF)
          pixel[1] = UInt8((row * 83) & 0xFF)
          pixel[2] = 0xCC
          pixel[3] = alpha
          pixel = pixel.advanced(by: 4)
        }
      }

      return buffer
    }

    private func alphaBytes(in buffer: CVPixelBuffer) throws -> [UInt8] {
      #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

      let width = CVPixelBufferGetWidth(buffer)
      let height = CVPixelBufferGetHeight(buffer)
      let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
      let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)

      var result: [UInt8] = []
      result.reserveCapacity(width * height)
      for row in 0..<height {
        var alpha = base.advanced(by: row * bytesPerRow + 3)
        for _ in 0..<width {
          result.append(alpha.pointee)
          alpha = alpha.advanced(by: 4)
        }
      }
      return result
    }

    private func installUnlockedPicture(
      _ buffer: CVPixelBuffer,
      on vout: CallbackLease.Vout
    )
      throws -> UnsafeMutableRawPointer {
      try #require(vout.context.installPendingPicture(buffer, isLocked: false))
    }

    // MARK: - Format callback

    @Test
    func `Format callback creates an isolated per-vout pool and opaque`() throws {
      let displayRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: displayRenderer)
      let vout = try lease.negotiate(width: 320, height: 240)

      #expect(vout.successCount == 1)
      #expect(vout.opaque != lease.handleOpaque)

      // Chroma should be forced to BGRA.
      let chromaString = String(
        bytes: vout.buffers.chroma.map { UInt8(bitPattern: $0) },
        encoding: .ascii
      )
      #expect(chromaString == "BGRA")

      // Pool + dimensions belong only to this vout, never the controller's
      // display renderer shared by every output on the handle.
      let state = vout.context.decodeRenderer.state.withLock { $0 }
      #expect(state.pool != nil)
      #expect(state.width == 320)
      #expect(state.height == 240)
      #expect(displayRenderer.state.withLock { $0.pool } == nil)

      // Pitch must match actual CVPixelBufferGetBytesPerRow, not the
      // nominal width * 4 — libVLC relies on this exact alignment.
      #expect(vout.buffers.pitches >= 320 * 4)
      #expect(vout.buffers.lines == 240)

      lease.close(vout)
      let cleared = vout.context.decodeRenderer.state.withLock { $0.pool }
      #expect(cleared == nil)
      #expect(!lease.handleContext.hasOpenVoutForTesting)
    }

    /// Two vouts can overlap during track/input replacement. Their setup
    /// callbacks start from the same handle opaque, but each must leave with
    /// independent dimensions, pitch, pool, and callback storage. Closing A
    /// must not invalidate B's next lock.
    @Test
    func `overlapping vouts keep independent pools through out-of-order cleanup`() throws {
      let displayRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: displayRenderer)
      let first = try lease.negotiate(width: 96, height: 54)
      let second = try lease.negotiate(width: 321, height: 179)

      #expect(first.opaque != second.opaque)
      #expect(first.context !== second.context)
      #expect(first.buffers.pitches != second.buffers.pitches)
      #expect(lease.handleContext.hasOpenVoutForTesting)

      let firstState = first.context.decodeRenderer.state.withLock {
        ($0.pool, $0.width, $0.height)
      }
      let secondState = second.context.decodeRenderer.state.withLock {
        ($0.pool, $0.width, $0.height)
      }
      let firstPool = try #require(firstState.0)
      let secondPool = try #require(secondState.0)
      #expect(firstState.1 == 96)
      #expect(firstState.2 == 54)
      #expect(secondState.1 == 321)
      #expect(secondState.2 == 179)
      #expect(
        Unmanaged.passUnretained(firstPool).toOpaque()
          != Unmanaged.passUnretained(secondPool).toOpaque()
      )

      var firstPlane: UnsafeMutableRawPointer?
      let firstPicture = withUnsafeMutablePointer(to: &firstPlane) {
        pixelBufferLockCallback(opaque: first.opaque, planes: $0)
      }
      let firstBuffer = try #require(
        firstPicture.map {
          Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! CVPixelBuffer
        }
      )
      #expect(CVPixelBufferGetWidth(firstBuffer) == 96)
      #expect(CVPixelBufferGetHeight(firstBuffer) == 54)
      pixelBufferUnlockCallback(opaque: first.opaque, picture: firstPicture, planes: nil)
      pixelBufferDisplayCallback(opaque: first.opaque, picture: firstPicture)

      var secondPlane: UnsafeMutableRawPointer?
      let secondPicture = withUnsafeMutablePointer(to: &secondPlane) {
        pixelBufferLockCallback(opaque: second.opaque, planes: $0)
      }
      let secondBuffer = try #require(
        secondPicture.map {
          Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! CVPixelBuffer
        }
      )
      #expect(CVPixelBufferGetWidth(secondBuffer) == 321)
      #expect(CVPixelBufferGetHeight(secondBuffer) == 179)
      pixelBufferUnlockCallback(opaque: second.opaque, picture: secondPicture, planes: nil)
      pixelBufferDisplayCallback(opaque: second.opaque, picture: secondPicture)

      lease.close(first)
      #expect(first.context.decodeRenderer.state.withLock { $0.pool } == nil)
      #expect(second.context.decodeRenderer.state.withLock { $0.pool } === secondPool)
      #expect(lease.handleContext.hasOpenVoutForTesting)

      var survivingPlane: UnsafeMutableRawPointer?
      let survivingPicture = withUnsafeMutablePointer(to: &survivingPlane) {
        pixelBufferLockCallback(opaque: second.opaque, planes: $0)
      }
      let survivingBuffer = try #require(
        survivingPicture.map {
          Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! CVPixelBuffer
        }
      )
      #expect(CVPixelBufferGetWidth(survivingBuffer) == 321)
      #expect(CVPixelBufferGetHeight(survivingBuffer) == 179)
      pixelBufferUnlockCallback(
        opaque: second.opaque,
        picture: survivingPicture,
        planes: nil
      )
      pixelBufferDisplayCallback(opaque: second.opaque, picture: survivingPicture)

      lease.close(second)
      #expect(!lease.handleContext.hasOpenVoutForTesting)
    }

    @Test
    func `Format callback with nil opaque returns 0`() {
      var chroma: [CChar] = Array(repeating: 0, count: 4)
      var width: UInt32 = 0
      var height: UInt32 = 0
      var pitches: UInt32 = 0
      var lines: UInt32 = 0

      let result = chroma.withUnsafeMutableBufferPointer { chromaBuf in
        withUnsafeMutablePointer(to: &width) { w in
          withUnsafeMutablePointer(to: &height) { h in
            withUnsafeMutablePointer(to: &pitches) { p in
              withUnsafeMutablePointer(to: &lines) { l in
                pixelBufferFormatCallback(
                  opaque: nil, // ← guard hit
                  chroma: chromaBuf.baseAddress,
                  width: w,
                  height: h,
                  pitches: p,
                  lines: l
                )
              }
            }
          }
        }
      }
      #expect(result == 0)
    }

    // MARK: - Lock / unlock callback

    @Test
    func `Lock callback returns nil before pool is initialized`() {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let retained = makeRetainedContext(renderer: renderer)
      defer { retained.release() }

      var plane: UnsafeMutableRawPointer?
      let result = withUnsafeMutablePointer(to: &plane) { planePtr in
        pixelBufferLockCallback(opaque: retained.toOpaque(), planes: planePtr)
      }
      // No pool yet → lock returns nil.
      #expect(result == nil)
    }

    @Test
    func `Lock callback with nil opaque returns nil`() {
      var plane: UnsafeMutableRawPointer?
      let result = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: nil, planes: $0)
      }
      #expect(result == nil)
    }

    @Test
    func `Lock then unlock round trip after format`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 320, height: 240)

      // Lock → get a pixel buffer handle, base address written into plane.
      var plane: UnsafeMutableRawPointer?
      let handle = withUnsafeMutablePointer(to: &plane) { planePtr in
        pixelBufferLockCallback(opaque: vout.opaque, planes: planePtr)
      }
      #expect(plane != nil)

      // Unlock balances the base-address lock through the owning vout.
      pixelBufferUnlockCallback(opaque: vout.opaque, picture: handle, planes: nil)
      #expect(vout.context.hasPendingPictureForTesting)

      lease.close(vout)
      #expect(!vout.context.hasPendingPictureForTesting)
    }

    /// Pinned vmem suppresses display when its temporary picture allocation
    /// fails. The vout context must therefore retain the successfully locked
    /// Core Video buffer until cleanup, then drain it without relying on a
    /// display callback that will never arrive.
    @Test
    func `Cleanup drains a picture whose native display was suppressed`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 64, height: 36)

      var plane: UnsafeMutableRawPointer?
      let picture = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      }
      #expect(picture != nil)
      #expect(plane != nil)
      pixelBufferUnlockCallback(opaque: vout.opaque, picture: picture, planes: nil)
      #expect(vout.context.hasPendingPictureForTesting)

      // No display callback: this is the exact branch taken when patched
      // vmem cannot allocate/copy its temporary picture.
      lease.close(vout)
      #expect(!vout.context.hasPendingPictureForTesting)
    }

    /// A failed subsequent lock has not superseded vmem's prior `pic_opaque`,
    /// so it must leave that pending owner intact for eventual cleanup.
    @Test
    func `Failed lock preserves the undisplayed predecessor until cleanup`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 64, height: 36)

      var firstPlane: UnsafeMutableRawPointer?
      let firstPicture = withUnsafeMutablePointer(to: &firstPlane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      }
      pixelBufferUnlockCallback(
        opaque: vout.opaque,
        picture: firstPicture,
        planes: nil
      )
      #expect(vout.context.hasPendingPictureForTesting)

      // Deterministically exercise the allocation-unavailable branch without
      // depending on process-wide memory pressure.
      vout.context.decodeRenderer.state.withLock { $0.pool = nil }
      var failedPlane: UnsafeMutableRawPointer?
      let failedPicture = withUnsafeMutablePointer(to: &failedPlane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      }
      #expect(failedPicture == nil)
      #expect(failedPlane == nil)
      #expect(vout.context.hasPendingPictureForTesting)

      lease.close(vout)
      #expect(!vout.context.hasPendingPictureForTesting)
    }

    @Test
    func `Decode pool threshold leaves plane untouched and recovers after release`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 64, height: 36)
      defer { lease.close(vout) }
      let pool = try #require(vout.context.decodeRenderer.state.withLock { $0.pool })
      let threshold = pixelBufferRendererPoolAllocationThreshold(width: 64, height: 36)
      expectNoDifference(threshold, 12)

      var heldBuffers: [CVPixelBuffer] = []
      for _ in 0..<threshold {
        let allocation = pixelBufferRendererAllocatePixelBuffer(
          from: pool,
          width: 64,
          height: 36
        )
        expectNoDifference(allocation.status, kCVReturnSuccess)
        try heldBuffers.append(#require(allocation.buffer))
      }

      let exhausted = pixelBufferRendererAllocatePixelBuffer(
        from: pool,
        width: 64,
        height: 36
      )
      expectNoDifference(exhausted.status, kCVReturnWouldExceedAllocationThreshold)
      #expect(exhausted.buffer == nil)

      let sentinel = try #require(UnsafeMutableRawPointer(bitPattern: 0x1))
      var failedPlane: UnsafeMutableRawPointer? = sentinel
      let failedPicture = withUnsafeMutablePointer(to: &failedPlane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      }
      #expect(failedPicture == nil)
      #expect(failedPlane == sentinel)
      #expect(!vout.context.hasPendingPictureForTesting)

      heldBuffers.removeLast()
      var recoveredPlane: UnsafeMutableRawPointer? = sentinel
      let recoveredPicture = try #require(withUnsafeMutablePointer(to: &recoveredPlane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      })
      #expect(recoveredPlane != sentinel)
      pixelBufferUnlockCallback(
        opaque: vout.opaque,
        picture: recoveredPicture,
        planes: nil
      )
      pixelBufferDisplayCallback(opaque: vout.opaque, picture: recoveredPicture)
      #expect(!vout.context.hasPendingPictureForTesting)
    }

    /// Pinned vmem owns only one `pic_opaque`. A second successful lock means
    /// an undisplayed predecessor can never arrive normally; replace it, then
    /// reject a synthetic stale display without consuming the successor.
    @Test
    func `Repeated lock drains predecessor and stale display cannot consume successor`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 64, height: 36)
      defer { lease.close(vout) }

      var firstPlane: UnsafeMutableRawPointer?
      let firstPicture = try #require(withUnsafeMutablePointer(to: &firstPlane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      })
      pixelBufferUnlockCallback(
        opaque: vout.opaque,
        picture: firstPicture,
        planes: nil
      )

      var secondPlane: UnsafeMutableRawPointer?
      let secondPicture = try #require(withUnsafeMutablePointer(to: &secondPlane) {
        pixelBufferLockCallback(opaque: vout.opaque, planes: $0)
      })
      #expect(firstPicture != secondPicture)
      #expect(vout.context.hasPendingPictureForTesting)

      pixelBufferDisplayCallback(opaque: vout.opaque, picture: firstPicture)
      #expect(vout.context.hasPendingPictureForTesting)

      pixelBufferUnlockCallback(
        opaque: vout.opaque,
        picture: secondPicture,
        planes: nil
      )
      pixelBufferDisplayCallback(opaque: vout.opaque, picture: secondPicture)
      #expect(!vout.context.hasPendingPictureForTesting)
    }

    @Test
    func `Unlock callback with nil picture is a no-op`() {
      // Purely a liveness test — the function must defensively accept
      // nil (which happens after a failed lock).
      pixelBufferUnlockCallback(opaque: nil, picture: nil, planes: nil)
    }

    // MARK: - Cleanup callback

    @Test
    func `Cleanup callback with nil opaque is a no-op`() {
      pixelBufferCleanupCallback(opaque: nil)
    }

    @Test
    func `Retiring callback context releases opaque only after native handle ends`() throws {
      weak var weakContext: PixelBufferRendererCallbackContext?
      weak var weakRenderer: PixelBufferRenderer?

      do {
        var renderer: PixelBufferRenderer? = PixelBufferRenderer(
          displayLayer: AVSampleBufferDisplayLayer()
        )
        let context = try PixelBufferRendererCallbackContext(renderer: #require(renderer))
        weakContext = context
        weakRenderer = renderer
        let retained = Unmanaged.passRetained(context)
        let opaque = retained.toOpaque()
        renderer = nil

        context.requestRetirement()
        #expect(weakContext != nil)
        #expect(weakRenderer == nil)

        context.nativePlayerHandleDidRelease(opaque: opaque)
      }

      #expect(weakContext == nil)
      #expect(weakRenderer == nil)
    }

    @Test
    func `Retirement keeps renderer alive for a callback already in flight`() throws {
      weak var weakContext: PixelBufferRendererCallbackContext?
      weak var weakRenderer: PixelBufferRenderer?

      do {
        var renderer: PixelBufferRenderer? = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let context = try PixelBufferRendererCallbackContext(renderer: #require(renderer))
        weakContext = context
        weakRenderer = renderer
        renderer = nil
        let retained = Unmanaged.passRetained(context)
        let opaque = retained.toOpaque()

        let result = context.withRenderer(opaque: opaque) { callbackRenderer in
          context.requestRetirement()
          context.nativePlayerHandleDidRelease(opaque: opaque)
          #expect(weakRenderer != nil)
          _ = callbackRenderer
          return true
        }

        #expect(result == true)
      }

      #expect(weakContext == nil)
      #expect(weakRenderer == nil)
    }

    @Test
    func `Retired callback context balances no-op callback entry`() throws {
      weak var weakContext: PixelBufferRendererCallbackContext?
      weak var weakRenderer: PixelBufferRenderer?

      do {
        var renderer: PixelBufferRenderer? = PixelBufferRenderer(
          displayLayer: AVSampleBufferDisplayLayer()
        )
        let context = try PixelBufferRendererCallbackContext(renderer: #require(renderer))
        weakContext = context
        weakRenderer = renderer
        let retained = Unmanaged.passRetained(context)
        let opaque = retained.toOpaque()
        renderer = nil

        context.requestRetirement()

        #expect(weakContext != nil)
        #expect(weakRenderer == nil)
        let result = context.withRenderer(opaque: opaque) { _ in true }
        #expect(result == nil)
        context.nativePlayerHandleDidRelease(opaque: opaque)
      }

      #expect(weakContext == nil)
      #expect(weakRenderer == nil)
    }

    @Test
    func `Retired callback context survives vout cleanup until native handle ends`() throws {
      weak var weakContext: PixelBufferRendererCallbackContext?
      weak var weakRenderer: PixelBufferRenderer?
      var handleOpaque: UnsafeMutableRawPointer?
      var voutOpaque: UnsafeMutableRawPointer?

      do {
        let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let context = PixelBufferRendererCallbackContext(renderer: renderer)
        weakContext = context
        weakRenderer = renderer
        let retained = Unmanaged.passRetained(context)
        handleOpaque = retained.toOpaque()

        var opaqueSlot: UnsafeMutableRawPointer? = handleOpaque
        var buffers = FormatBuffers()
        let result = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePtr in
          buffers.chroma.withUnsafeMutableBufferPointer { chromaBuf in
            withUnsafeMutablePointer(to: &buffers.width) { widthPtr in
              withUnsafeMutablePointer(to: &buffers.height) { heightPtr in
                withUnsafeMutablePointer(to: &buffers.pitches) { pitchPtr in
                  withUnsafeMutablePointer(to: &buffers.lines) { linesPtr in
                    pixelBufferFormatCallback(
                      opaque: opaquePtr,
                      chroma: chromaBuf.baseAddress,
                      width: widthPtr,
                      height: heightPtr,
                      pitches: pitchPtr,
                      lines: linesPtr
                    )
                  }
                }
              }
            }
          }
        }
        #expect(result == 1)
        voutOpaque = opaqueSlot
        #expect(voutOpaque != handleOpaque)
        #expect(context.hasOpenVoutForTesting)

        context.requestRetirement()
      }

      #expect(weakContext != nil)
      #expect(weakRenderer == nil)

      pixelBufferCleanupCallback(opaque: voutOpaque)

      #expect(weakContext != nil)
      #expect(weakRenderer == nil)

      try weakContext?.nativePlayerHandleDidRelease(opaque: #require(handleOpaque))

      #expect(weakContext == nil)
      #expect(weakRenderer == nil)
    }

    // MARK: - Display callback

    /// Synthesize a BGRA `CVPixelBuffer`, hand it to the display callback,
    /// and verify the function wraps it into a `CMSampleBuffer` and
    /// enqueues it onto the attached display layer without crashing.
    ///
    /// Runs on `@MainActor` because `AVSampleBufferDisplayLayer` is not
    /// `Sendable` — the layer and the renderer must be allocated on the
    /// same actor. The callback itself is invoked synchronously; the
    /// renderer's async enqueue is awaited via a short `Task.sleep`.
    @MainActor
    @Test
    func `Display callback enqueues a sample onto the display layer`() async throws {
      let displayLayer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: displayLayer)
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 2, height: 2)
      defer { lease.close(vout) }

      let pb = try makeBGRAImageBuffer(width: 2, height: 2)

      let pictureHandle = try installUnlockedPicture(pb, on: vout)

      pixelBufferDisplayCallback(opaque: vout.opaque, picture: pictureHandle)

      // Give the renderer's async enqueue queue a moment to settle.
      try? await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    @Test
    func `Display callback does not mutate source frame bytes`() throws {
      let displayLayer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: displayLayer)
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 3, height: 2)
      defer { lease.close(vout) }

      let pb = try makeBGRAImageBuffer(width: 3, height: 2, alpha: 37)
      let expectedAlphaBytes = try alphaBytes(in: pb)

      let pictureHandle = try installUnlockedPicture(pb, on: vout)
      pixelBufferDisplayCallback(opaque: vout.opaque, picture: pictureHandle)

      try expectNoDifference(alphaBytes(in: pb), expectedAlphaBytes)
    }

    @MainActor
    @Test
    func `Display callback uses configured timebase for presentation time`() throws {
      let displayLayer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: displayLayer)
      let lease = CallbackLease(displayRenderer: renderer)
      let vout = try lease.negotiate(width: 2, height: 2)
      defer { lease.close(vout) }

      let clock = CMClockGetHostTimeClock()
      var timebase: CMTimebase?
      let status = CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault,
        sourceClock: clock,
        timebaseOut: &timebase
      )
      #expect(status == noErr)
      let tb = try #require(timebase)
      CMTimebaseSetTime(tb, time: CMTime(seconds: 3, preferredTimescale: 1000))
      renderer.setTimebase(tb)

      let pb = try makeBGRAImageBuffer(width: 2, height: 2)
      let pictureHandle = try installUnlockedPicture(pb, on: vout)

      pixelBufferDisplayCallback(opaque: vout.opaque, picture: pictureHandle)
    }

    /// A nil `opaque` guards-out early.
    @Test
    func `Display callback with nil opaque is a no-op`() {
      pixelBufferDisplayCallback(opaque: nil, picture: nil)
    }

    /// A non-nil `opaque` with a nil `picture` also guards-out without
    /// touching the display layer.
    @MainActor
    @Test
    func `Display callback with nil picture is a no-op`() {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let retained = makeRetainedContext(renderer: renderer)
      defer { retained.release() }

      pixelBufferDisplayCallback(opaque: retained.toOpaque(), picture: nil)
    }

    // MARK: - Pool floor / deferred retirement

    /// Drive the format callback and read back the negotiated pool's
    /// minimum buffer count via its attributes.
    private func formatCallbackPoolFloor(
      lease: CallbackLease,
      width: UInt32,
      height: UInt32
    )
      throws -> (successCount: UInt32, poolFloor: Int) {
      let vout = try lease.negotiate(width: width, height: height)
      defer { lease.close(vout) }
      let pool = try #require(vout.context.decodeRenderer.state.withLock { $0.pool })
      let attrs = try #require(CVPixelBufferPoolGetAttributes(pool) as? [String: Any])
      let minNumber = try #require(
        attrs[kCVPixelBufferPoolMinimumBufferCountKey as String] as? NSNumber
      )
      return (vout.successCount, minNumber.intValue)
    }

    /// The resident pool floor is byte-budgeted: 4K drains down to a small
    /// floor while SD keeps the full recycled floor. The format return reports
    /// the single allocation proven during negotiation, not decoder headroom.
    @Test
    func `Pool floor is byte-budgeted independently of format success count`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)

      let uhd = try formatCallbackPoolFloor(
        lease: lease,
        width: 3840,
        height: 2160
      )
      #expect(uhd.successCount == 1)
      #expect(uhd.poolFloor >= 3)
      #expect(uhd.poolFloor <= 4)

      let sd = try formatCallbackPoolFloor(
        lease: lease,
        width: 320,
        height: 240
      )
      #expect(sd.successCount == 1)
      #expect(sd.poolFloor == 12)
    }

    /// Three 32 MiB BGRA buffers exactly fit the 96 MiB resident budget. One
    /// pixel column beyond that deterministic boundary must switch the floor
    /// to a single buffer instead of pinning three oversized frames.
    @Test
    func `Pool floor drops to one immediately above the large-frame threshold`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let lease = CallbackLease(displayRenderer: renderer)

      let atBoundary = try formatCallbackPoolFloor(
        lease: lease,
        width: 4096,
        height: 2048
      )
      #expect(atBoundary.successCount == 1)
      #expect(atBoundary.poolFloor == 3)

      let aboveBoundary = try formatCallbackPoolFloor(
        lease: lease,
        width: 4097,
        height: 2048
      )
      #expect(aboveBoundary.successCount == 1)
      #expect(aboveBoundary.poolFloor == 1)
    }

    /// Clearing the media-player callback variables does not update a vout
    /// that is concurrently opening and may already have copied the opaque.
    /// `voutOpen == false` therefore cannot prove that the opaque is safe to
    /// release: the format callback may simply not have arrived yet.
    @Test
    func `Retired opaque remains callable until native handle lifetime ends`() throws {
      weak var weakContext: PixelBufferRendererCallbackContext?
      var opaque: UnsafeMutableRawPointer?

      do {
        let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let context = PixelBufferRendererCallbackContext(renderer: renderer)
        weakContext = context
        opaque = Unmanaged.passRetained(context).toOpaque()
        context.requestRetirement()
      }

      #expect(weakContext != nil)
      let handleOpaque = try #require(opaque)
      var voutOpaque: UnsafeMutableRawPointer? = handleOpaque
      var chroma = [CChar](repeating: 0, count: 4)
      var width: UInt32 = 96
      var height: UInt32 = 54
      var pitch: UInt32 = 0
      var lines: UInt32 = 0
      let result = withUnsafeMutablePointer(to: &voutOpaque) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          pixelBufferFormatCallback(
            opaque: opaquePointer,
            chroma: chromaBuffer.baseAddress,
            width: &width,
            height: &height,
            pitches: &pitch,
            lines: &lines
          )
        }
      }
      #expect(result == 1)
      let negotiatedOpaque = try #require(voutOpaque)
      #expect(negotiatedOpaque != handleOpaque)

      var plane: UnsafeMutableRawPointer?
      let lateLock = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: negotiatedOpaque, planes: $0)
      }
      #expect(lateLock != nil)
      #expect(plane != nil)
      pixelBufferUnlockCallback(
        opaque: negotiatedOpaque,
        picture: lateLock,
        planes: nil
      )
      pixelBufferDisplayCallback(opaque: negotiatedOpaque, picture: lateLock)
      pixelBufferCleanupCallback(opaque: negotiatedOpaque)
      #expect(weakContext != nil)

      weakContext?.nativePlayerHandleDidRelease(opaque: handleOpaque)

      #expect(weakContext == nil)
    }
  }
}
#endif
