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
    func `invalid crop and orientation fail closed`() {
      let outOfBoundsCrop = PixelBufferSourceGeometry(
        geometry(codedWidth: 727, visibleWidth: 720, xOffset: 8)
      )
      let unknownOrientation = PixelBufferSourceGeometry(geometry(orientation: 8))

      #expect(!outOfBoundsCrop.isValid)
      #expect(outOfBoundsCrop.squarePixelDeliveryDimensions == nil)
      #expect(!unknownOrientation.isValid)
      #expect(unknownOrientation.squarePixelDeliveryDimensions == nil)
    }

    /// Used to fail closed. A sample aspect with no integer square-pixel size
    /// is ordinary in real material, and refusing it left audio playing over a
    /// picture that never appeared (issue 250).
    @Test
    func `inexact PAR rounds the expanded axis to the nearest pixel`() {
      let widthExpanding = PixelBufferSourceGeometry(
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
      let heightExpanding = PixelBufferSourceGeometry(
        geometry(
          codedWidth: 7,
          codedHeight: 5,
          visibleWidth: 7,
          visibleHeight: 5,
          xOffset: 0,
          yOffset: 0,
          sarNumerator: 2,
          sarDenominator: 3
        )
      )

      // 5 * 3 / 2 = 7.5, and the half rounds up.
      #expect(widthExpanding.squarePixelDeliveryDimensions?.width == 8)
      #expect(widthExpanding.squarePixelDeliveryDimensions?.height == 7)
      #expect(heightExpanding.squarePixelDeliveryDimensions?.width == 7)
      #expect(heightExpanding.squarePixelDeliveryDimensions?.height == 8)
    }

    struct DeliveryCase: Sendable, CustomTestStringConvertible {
      let visibleWidth: UInt32
      let visibleHeight: UInt32
      let sarNumerator: UInt32
      let sarDenominator: UInt32
      let width: UInt32
      let height: UInt32

      var testDescription: String {
        "\(visibleWidth)x\(visibleHeight) SAR \(sarNumerator):\(sarDenominator)"
      }
    }

    /// Geometries seen in real streams and rips. Every delivery size has to
    /// pass the tolerance the vmem output applies to it, or libVLC refuses the
    /// output and the picture never appears.
    static let deliveryCases: [DeliveryCase] = [
      // Issue 250: no integer size exists below 4085x1734.
      DeliveryCase(visibleWidth: 1920, visibleHeight: 816, sarNumerator: 817, sarDenominator: 816, width: 1922, height: 816),
      // Loose-anamorphic rips with mod-2 rounding.
      DeliveryCase(visibleWidth: 1916, visibleHeight: 796, sarNumerator: 2304, sarDenominator: 2299, width: 1920, height: 796),
      DeliveryCase(visibleWidth: 854, visibleHeight: 480, sarNumerator: 1279, sarDenominator: 1280, width: 854, height: 480),
      DeliveryCase(visibleWidth: 1280, visibleHeight: 534, sarNumerator: 2136, sarDenominator: 2135, width: 1281, height: 534),
      // PAL and NTSC DVD, 4:3 and 16:9.
      DeliveryCase(visibleWidth: 720, visibleHeight: 576, sarNumerator: 16, sarDenominator: 15, width: 768, height: 576),
      DeliveryCase(visibleWidth: 720, visibleHeight: 576, sarNumerator: 64, sarDenominator: 45, width: 1024, height: 576),
      DeliveryCase(visibleWidth: 720, visibleHeight: 480, sarNumerator: 8, sarDenominator: 9, width: 720, height: 540),
      DeliveryCase(visibleWidth: 720, visibleHeight: 480, sarNumerator: 32, sarDenominator: 27, width: 720, height: 405),
      DeliveryCase(visibleWidth: 720, visibleHeight: 576, sarNumerator: 12, sarDenominator: 11, width: 720, height: 528),
      DeliveryCase(visibleWidth: 704, visibleHeight: 480, sarNumerator: 10, sarDenominator: 11, width: 704, height: 528),
      // HDV, and 853x480 stored as 720x480.
      DeliveryCase(visibleWidth: 1440, visibleHeight: 1080, sarNumerator: 4, sarDenominator: 3, width: 1920, height: 1080),
      DeliveryCase(visibleWidth: 720, visibleHeight: 480, sarNumerator: 853, sarDenominator: 720, width: 853, height: 480),
      // Square pixels are delivered untouched.
      DeliveryCase(visibleWidth: 1920, visibleHeight: 1080, sarNumerator: 1, sarDenominator: 1, width: 1920, height: 1080)
    ]

    @Test(arguments: deliveryCases)
    func `delivery size stays within the vmem square-pixel tolerance`(
      testCase: DeliveryCase
    )
      throws {
      let source = PixelBufferSourceGeometry(
        geometry(
          codedWidth: testCase.visibleWidth,
          codedHeight: testCase.visibleHeight,
          visibleWidth: testCase.visibleWidth,
          visibleHeight: testCase.visibleHeight,
          xOffset: 0,
          yOffset: 0,
          sarNumerator: testCase.sarNumerator,
          sarDenominator: testCase.sarDenominator
        )
      )

      let delivery = try #require(source.squarePixelDeliveryDimensions)

      #expect(delivery.width == testCase.width)
      #expect(delivery.height == testCase.height)
      #expect(
        source.isWithinSquarePixelTolerance(
          width: delivery.width,
          height: delivery.height
        ),
        "libVLC's vmem output would refuse this size"
      )
    }

    /// The tolerance has to stay a real bound: delivering the visible size of
    /// an anamorphic source unchanged is what it exists to refuse.
    @Test
    func `tolerance refuses a size more than half a pixel off`() {
      let issue250 = PixelBufferSourceGeometry(
        geometry(
          codedWidth: 1920,
          codedHeight: 816,
          visibleWidth: 1920,
          visibleHeight: 816,
          xOffset: 0,
          yOffset: 0,
          sarNumerator: 817,
          sarDenominator: 816
        )
      )
      let dvd = PixelBufferSourceGeometry(geometry())

      #expect(issue250.isWithinSquarePixelTolerance(width: 1922, height: 816))
      #expect(!issue250.isWithinSquarePixelTolerance(width: 1920, height: 816))
      #expect(dvd.isWithinSquarePixelTolerance(width: 768, height: 480))
      #expect(!dvd.isWithinSquarePixelTolerance(width: 720, height: 480))
      #expect(!dvd.isWithinSquarePixelTolerance(width: 0, height: 480))
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
      #expect(
        handleContext.latestSourceDeliverySnapshot
          == PixelBufferVoutSourceSnapshot(
            voutGeneration: vout.voutGeneration,
            width: 768,
            height: 480
          )
      )
    }

    @Test
    func `source delivery telemetry follows the newest active vout`() throws {
      let displayRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let handleContext = PixelBufferRendererCallbackContext(renderer: displayRenderer)
      let handleOpaque = Unmanaged.passRetained(handleContext).toOpaque()
      defer {
        Unmanaged<PixelBufferRendererCallbackContext>.fromOpaque(handleOpaque).release()
      }
      let firstRenderer = PixelBufferRenderer()
      firstRenderer.state.withLock {
        $0.width = 1920
        $0.height = 1080
      }
      let secondRenderer = PixelBufferRenderer()
      secondRenderer.state.withLock {
        $0.width = 3840
        $0.height = 2160
      }
      let geometry = PixelBufferSourceGeometry(fullFrameWidth: 2, height: 2)
      let first = try #require(
        handleContext.makeVoutContext(
          handleOpaque: handleOpaque,
          decodeRenderer: firstRenderer,
          sourceGeometry: geometry
        )
      )
      let second = try #require(
        handleContext.makeVoutContext(
          handleOpaque: handleOpaque,
          decodeRenderer: secondRenderer,
          sourceGeometry: geometry
        )
      )

      #expect(handleContext.latestSourceDeliverySnapshot?.width == 3840)
      #expect(handleContext.latestSourceDeliverySnapshot?.height == 2160)
      second.cleanupDecodeStorage()
      #expect(handleContext.latestSourceDeliverySnapshot?.width == 1920)
      #expect(handleContext.latestSourceDeliverySnapshot?.height == 1080)
      first.cleanupDecodeStorage()
      #expect(handleContext.latestSourceDeliverySnapshot == nil)
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
