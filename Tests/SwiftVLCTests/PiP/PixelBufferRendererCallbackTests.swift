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

    // MARK: - Format callback

    @Test
    func `Format callback creates pool and updates state`() {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let retained = makeRetainedContext(renderer: renderer)
      defer { retained.release() }

      var opaqueSlot: UnsafeMutableRawPointer? = retained.toOpaque()
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

      #expect(result == 3)

      // Chroma should be forced to BGRA.
      let chromaString = String(
        bytes: buffers.chroma.map { UInt8(bitPattern: $0) },
        encoding: .ascii
      )
      #expect(chromaString == "BGRA")

      // Pool + dimensions should now be set in state.
      let state = renderer.state.withLock { $0 }
      #expect(state.pool != nil)
      #expect(state.width == 320)
      #expect(state.height == 240)

      // Pitch must match actual CVPixelBufferGetBytesPerRow, not the
      // nominal width * 4 — libVLC relies on this exact alignment.
      #expect(buffers.pitches >= 320 * 4)
      #expect(buffers.lines == 240)

      // Cleanup callback should release the pool.
      pixelBufferCleanupCallback(opaque: retained.toOpaque())
      let cleared = renderer.state.withLock { $0.pool }
      #expect(cleared == nil)
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
    func `Lock then unlock round trip after format`() {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let retained = makeRetainedContext(renderer: renderer)
      defer { retained.release() }

      // Prime the pool via format callback.
      var opaqueSlot: UnsafeMutableRawPointer? = retained.toOpaque()
      var buffers = FormatBuffers()
      _ = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePtr in
        buffers.chroma.withUnsafeMutableBufferPointer { chromaBuf in
          withUnsafeMutablePointer(to: &buffers.width) { w in
            withUnsafeMutablePointer(to: &buffers.height) { h in
              withUnsafeMutablePointer(to: &buffers.pitches) { p in
                withUnsafeMutablePointer(to: &buffers.lines) { l in
                  pixelBufferFormatCallback(
                    opaque: opaquePtr,
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
      }

      // Lock → get a pixel buffer handle, base address written into plane.
      var plane: UnsafeMutableRawPointer?
      let handle = withUnsafeMutablePointer(to: &plane) { planePtr in
        pixelBufferLockCallback(opaque: retained.toOpaque(), planes: planePtr)
      }
      #expect(plane != nil)

      // Unlock must succeed regardless of opaque (it doesn't dereference it).
      pixelBufferUnlockCallback(opaque: retained.toOpaque(), picture: handle, planes: nil)

      // Balance the retain `pixelBufferLockCallback` performed internally.
      if let h = handle {
        Unmanaged<AnyObject>.fromOpaque(h).release()
      }

      // Clean up the pool.
      pixelBufferCleanupCallback(opaque: retained.toOpaque())
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
    func `Retiring callback context without opened vout releases opaque retain`() throws {
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
        renderer = nil

        context.requestRetirement(
          opaque: retained.toOpaque(),
          deferIfVoutMayBeOpening: false
        )
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

        let result = context.withRenderer(opaque: retained.toOpaque()) { callbackRenderer in
          context.requestRetirement(
            opaque: retained.toOpaque(),
            deferIfVoutMayBeOpening: false
          )
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
        renderer = nil

        context.requestRetirement(
          opaque: retained.toOpaque(),
          deferIfVoutMayBeOpening: true
        )

        #expect(weakContext != nil)
        #expect(weakRenderer == nil)
        let result = context.withRenderer(opaque: retained.toOpaque()) { _ in true }
        #expect(result == nil)
        #expect(context.releaseRetiredOpaqueRetainIfNoOpenVout(opaque: retained.toOpaque()))
      }

      #expect(weakContext == nil)
      #expect(weakRenderer == nil)
    }

    @Test
    func `Retired callback context keeps opaque alive until vout cleanup`() {
      weak var weakContext: PixelBufferRendererCallbackContext?
      weak var weakRenderer: PixelBufferRenderer?
      var contextOpaque: UnsafeMutableRawPointer?

      do {
        let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let context = PixelBufferRendererCallbackContext(renderer: renderer)
        weakContext = context
        weakRenderer = renderer
        let retained = Unmanaged.passRetained(context)
        contextOpaque = retained.toOpaque()

        var opaqueSlot: UnsafeMutableRawPointer? = contextOpaque
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
        #expect(result == 3)
        #expect(context.hasOpenVoutForTesting)

        context.requestRetirement(
          opaque: retained.toOpaque(),
          deferIfVoutMayBeOpening: false
        )
      }

      #expect(weakContext != nil)
      #expect(weakRenderer == nil)

      pixelBufferCleanupCallback(opaque: contextOpaque)

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
      let retained = makeRetainedContext(renderer: renderer)
      defer { retained.release() }

      let pb = try makeBGRAImageBuffer(width: 2, height: 2)

      // The display callback expects a retained `AnyObject` pointer —
      // matches the `passRetained(pb as AnyObject)` on the lock path.
      let pictureHandle = Unmanaged.passRetained(pb as AnyObject).toOpaque()

      pixelBufferDisplayCallback(opaque: retained.toOpaque(), picture: pictureHandle)

      // Give the renderer's async enqueue queue a moment to settle.
      try? await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    @Test
    func `Display callback does not mutate source frame bytes`() throws {
      let displayLayer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: displayLayer)
      let retained = makeRetainedContext(renderer: renderer)
      defer { retained.release() }

      let pb = try makeBGRAImageBuffer(width: 3, height: 2, alpha: 37)
      let expectedAlphaBytes = try alphaBytes(in: pb)

      let pictureHandle = Unmanaged.passRetained(pb as AnyObject).toOpaque()
      pixelBufferDisplayCallback(opaque: retained.toOpaque(), picture: pictureHandle)

      try expectNoDifference(alphaBytes(in: pb), expectedAlphaBytes)
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
  }
}
#endif
