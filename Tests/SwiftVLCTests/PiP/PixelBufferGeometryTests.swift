#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CLibVLC
import CoreVideo
import Synchronization
import Testing

extension Integration {
  struct PixelBufferGeometryTests {
    private func geometry(
      codedWidth: UInt32 = 736,
      codedHeight: UInt32 = 496,
      visibleWidth: UInt32 = 720,
      visibleHeight: UInt32 = 480,
      xOffset: UInt32 = 8,
      yOffset: UInt32 = 4,
      sarNumerator: UInt32 = 16,
      sarDenominator: UInt32 = 15,
      orientation: UInt32 = 0
    ) -> swiftvlc_video_format_geometry_t {
      var value = swiftvlc_video_format_geometry_t()
      value.coded_width = codedWidth
      value.coded_height = codedHeight
      value.visible_width = visibleWidth
      value.visible_height = visibleHeight
      value.x_offset = xOffset
      value.y_offset = yOffset
      value.sar_num = sarNumerator
      value.sar_den = sarDenominator
      value.source_orientation = orientation
      return value
    }

    @Test
    func `C geometry ABI has the pinned fixed-width layout`() {
      #expect(MemoryLayout<swiftvlc_video_format_geometry_t>.size == 36)
      #expect(MemoryLayout<swiftvlc_video_format_geometry_t>.stride == 36)
      #expect(MemoryLayout<swiftvlc_video_format_geometry_t>.alignment == 4)
    }

    @Test
    func `asymmetric crop and 16 by 15 SAR produce exact square pixels`() {
      let source = PixelBufferSourceGeometry(geometry())

      #expect(source.isValid)
      #expect(source.codedWidth == 736)
      #expect(source.codedHeight == 496)
      #expect(source.visibleWidth == 720)
      #expect(source.visibleHeight == 480)
      #expect(source.xOffset == 8)
      #expect(source.yOffset == 4)
      #expect(source.sarNumerator == 16)
      #expect(source.sarDenominator == 15)
      #expect(source.squarePixelDeliveryDimensions?.width == 768)
      #expect(source.squarePixelDeliveryDimensions?.height == 480)
    }

    @Test(arguments: Array(UInt32(0)...UInt32(7)))
    func `every libVLC orientation value is retained as diagnostic metadata`(
      orientation: UInt32
    ) {
      let source = PixelBufferSourceGeometry(geometry(orientation: orientation))

      #expect(source.isValid)
      #expect(source.sourceOrientationRawValue == orientation)
      #expect(source.squarePixelDeliveryDimensions?.width == 768)
      #expect(source.squarePixelDeliveryDimensions?.height == 480)
    }

    @Test
    func `reciprocal SAR expands height exactly`() {
      let source = PixelBufferSourceGeometry(
        geometry(sarNumerator: 15, sarDenominator: 16)
      )

      #expect(source.squarePixelDeliveryDimensions?.width == 720)
      #expect(source.squarePixelDeliveryDimensions?.height == 512)
    }

    @Test
    func `invalid crop orientation and inexact PAR fail closed`() {
      let outOfBoundsCrop = PixelBufferSourceGeometry(
        geometry(codedWidth: 727, visibleWidth: 720, xOffset: 8)
      )
      let unknownOrientation = PixelBufferSourceGeometry(geometry(orientation: 8))
      let inexactPAR = PixelBufferSourceGeometry(
        geometry(
          codedWidth: 5,
          codedHeight: 7,
          visibleWidth: 5,
          visibleHeight: 7,
          xOffset: 0,
          yOffset: 0,
          sarNumerator: 3,
          sarDenominator: 2
        )
      )

      #expect(!outOfBoundsCrop.isValid)
      #expect(outOfBoundsCrop.squarePixelDeliveryDimensions == nil)
      #expect(!unknownOrientation.isValid)
      #expect(unknownOrientation.squarePixelDeliveryDimensions == nil)
      #expect(inexactPAR.isValid)
      #expect(inexactPAR.squarePixelDeliveryDimensions == nil)
    }

    @Test
    func `extended callback copies geometry and negotiates a per-vout pool`() throws {
      let displayRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let handleContext = PixelBufferRendererCallbackContext(renderer: displayRenderer)
      let handleOpaque = Unmanaged.passRetained(handleContext).toOpaque()
      defer {
        Unmanaged<PixelBufferRendererCallbackContext>.fromOpaque(handleOpaque).release()
      }

      var opaque: UnsafeMutableRawPointer? = handleOpaque
      var chroma = [CChar](repeating: 0, count: 4)
      var source = geometry(orientation: 5)
      var outputWidth: UInt32 = 1
      var outputHeight: UInt32 = 1
      var pitch: UInt32 = 0
      var lines: UInt32 = 0

      let success = withUnsafeMutablePointer(to: &opaque) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          withUnsafePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &outputWidth) { widthPointer in
              withUnsafeMutablePointer(to: &outputHeight) { heightPointer in
                withUnsafeMutablePointer(to: &pitch) { pitchPointer in
                  withUnsafeMutablePointer(to: &lines) { linesPointer in
                    pixelBufferFormatCallbackEx(
                      opaque: opaquePointer,
                      chroma: chromaBuffer.baseAddress,
                      sourceGeometry: sourcePointer,
                      outputWidth: widthPointer,
                      outputHeight: heightPointer,
                      pitches: pitchPointer,
                      lines: linesPointer
                    )
                  }
                }
              }
            }
          }
        }
      }

      let voutOpaque = try #require(opaque)
      #expect(voutOpaque != handleOpaque)
      defer { pixelBufferCleanupCallback(opaque: voutOpaque) }
      let vout = try #require(pixelBufferVoutCallbackContext(from: voutOpaque))

      #expect(success == pixelBufferRendererFormatSuccessCount)
      #expect(String(bytes: chroma.map { UInt8(bitPattern: $0) }, encoding: .ascii) == "BGRA")
      #expect(outputWidth == 768)
      #expect(outputHeight == 480)
      #expect(pitch >= outputWidth * 4)
      #expect(lines == outputHeight)
      #expect(vout.sourceGeometry == PixelBufferSourceGeometry(source))
      #expect(vout.sourceGeometry.sourceOrientationRawValue == 5)
      #expect(vout.decodeRenderer.state.withLock { $0.width } == 768)
      #expect(vout.decodeRenderer.state.withLock { $0.height } == 480)
    }

    @Test
    func `extended callback rejects malformed geometry without opening a vout`() {
      let displayRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let handleContext = PixelBufferRendererCallbackContext(renderer: displayRenderer)
      let handleOpaque = Unmanaged.passRetained(handleContext).toOpaque()
      defer {
        Unmanaged<PixelBufferRendererCallbackContext>.fromOpaque(handleOpaque).release()
      }

      var opaque: UnsafeMutableRawPointer? = handleOpaque
      var chroma = [CChar](repeating: 0x58, count: 4)
      var source = geometry(codedWidth: 727, visibleWidth: 720, xOffset: 8)
      var outputWidth: UInt32 = 111
      var outputHeight: UInt32 = 222
      var pitch: UInt32 = 333
      var lines: UInt32 = 444

      let success = withUnsafeMutablePointer(to: &opaque) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          withUnsafePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &outputWidth) { widthPointer in
              withUnsafeMutablePointer(to: &outputHeight) { heightPointer in
                withUnsafeMutablePointer(to: &pitch) { pitchPointer in
                  withUnsafeMutablePointer(to: &lines) { linesPointer in
                    pixelBufferFormatCallbackEx(
                      opaque: opaquePointer,
                      chroma: chromaBuffer.baseAddress,
                      sourceGeometry: sourcePointer,
                      outputWidth: widthPointer,
                      outputHeight: heightPointer,
                      pitches: pitchPointer,
                      lines: linesPointer
                    )
                  }
                }
              }
            }
          }
        }
      }

      #expect(success == 0)
      #expect(opaque == handleOpaque)
      #expect(outputWidth == 111)
      #expect(outputHeight == 222)
      #expect(pitch == 333)
      #expect(lines == 444)
      #expect(chroma.allSatisfy { $0 == 0x58 })
      #expect(!handleContext.hasOpenVoutForTesting)
    }
  }
}
#endif
