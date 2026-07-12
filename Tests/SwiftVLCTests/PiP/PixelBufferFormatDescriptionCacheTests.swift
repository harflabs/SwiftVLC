#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import CoreVideo
import CustomDump
import Synchronization
import Testing

extension Integration {
  struct PixelBufferFormatDescriptionCacheTests {
    @Test
    func `Equivalent buffers reuse one exact format description`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let firstBuffer = try makePixelBuffer(width: 16, height: 9)
      let secondBuffer = try makePixelBuffer(width: 16, height: 9)
      let generation = renderer.state.withLock { $0.renderGeneration }

      let first = try #require(
        renderer.formatDescription(for: firstBuffer, generation: generation)
      )
      let second = try #require(
        renderer.formatDescription(for: secondBuffer, generation: generation)
      )

      #expect(first === second)
      #expect(CMVideoFormatDescriptionMatchesImageBuffer(second, imageBuffer: secondBuffer))
      expectNoDifference(
        renderer.state.withLock { $0.formatDescriptionCreationCount },
        UInt64(1)
      )
    }

    @Test
    func `Dimension and pixel format changes replace the cached description`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let generation = renderer.state.withLock { $0.renderGeneration }
      let originalBuffer = try makePixelBuffer(width: 16, height: 9)
      let widerBuffer = try makePixelBuffer(width: 32, height: 9)
      let argbBuffer = try makePixelBuffer(
        width: 32,
        height: 9,
        pixelFormat: kCVPixelFormatType_32ARGB
      )

      let original = try #require(
        renderer.formatDescription(for: originalBuffer, generation: generation)
      )
      #expect(!CMVideoFormatDescriptionMatchesImageBuffer(original, imageBuffer: widerBuffer))

      let wider = try #require(
        renderer.formatDescription(for: widerBuffer, generation: generation)
      )
      #expect(original !== wider)
      #expect(CMVideoFormatDescriptionMatchesImageBuffer(wider, imageBuffer: widerBuffer))
      expectNoDifference(CMVideoFormatDescriptionGetDimensions(wider).width, Int32(32))
      expectNoDifference(CMVideoFormatDescriptionGetDimensions(wider).height, Int32(9))
      #expect(!CMVideoFormatDescriptionMatchesImageBuffer(wider, imageBuffer: argbBuffer))

      let argb = try #require(
        renderer.formatDescription(for: argbBuffer, generation: generation)
      )
      #expect(wider !== argb)
      #expect(CMVideoFormatDescriptionMatchesImageBuffer(argb, imageBuffer: argbBuffer))
      expectNoDifference(CMFormatDescriptionGetMediaSubType(argb), kCVPixelFormatType_32ARGB)
      expectNoDifference(
        renderer.state.withLock { $0.formatDescriptionCreationCount },
        UInt64(3)
      )
    }

    @Test
    func `Relevant attachment mutations replace stale descriptions`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let buffer = try makePixelBuffer(width: 16, height: 9)
      let generation = renderer.state.withLock { $0.renderGeneration }

      CVBufferSetAttachment(
        buffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        .shouldPropagate
      )
      let rec709 = try #require(
        renderer.formatDescription(for: buffer, generation: generation)
      )

      CVBufferSetAttachment(
        buffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_P3_D65,
        .shouldPropagate
      )
      #expect(!CMVideoFormatDescriptionMatchesImageBuffer(rec709, imageBuffer: buffer))
      expectNoDifference(
        sampleCreationStatus(buffer: buffer, description: rec709),
        kCMSampleBufferError_InvalidMediaFormat
      )

      let displayP3 = try #require(
        renderer.formatDescription(for: buffer, generation: generation)
      )
      #expect(rec709 !== displayP3)
      #expect(CMVideoFormatDescriptionMatchesImageBuffer(displayP3, imageBuffer: buffer))
      expectNoDifference(sampleCreationStatus(buffer: buffer, description: displayP3), noErr)

      CVBufferRemoveAttachment(buffer, kCVImageBufferColorPrimariesKey)
      #expect(!CMVideoFormatDescriptionMatchesImageBuffer(displayP3, imageBuffer: buffer))

      let untagged = try #require(
        renderer.formatDescription(for: buffer, generation: generation)
      )
      #expect(displayP3 !== untagged)
      #expect(CMVideoFormatDescriptionMatchesImageBuffer(untagged, imageBuffer: buffer))
      expectNoDifference(sampleCreationStatus(buffer: buffer, description: untagged), noErr)
      expectNoDifference(
        renderer.state.withLock { $0.formatDescriptionCreationCount },
        UInt64(3)
      )
    }

    @Test
    func `A generation change clears the cache and stale work cannot evict its successor`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let buffer = try makePixelBuffer(width: 16, height: 9)
      let firstGeneration = renderer.state.withLock { $0.renderGeneration }
      let first = try #require(
        renderer.formatDescription(for: buffer, generation: firstGeneration)
      )

      renderer.setRenderSize(CMVideoDimensions(width: 16, height: 9))
      let secondGeneration = renderer.state.withLock { $0.renderGeneration }
      #expect(secondGeneration != firstGeneration)
      #expect(renderer.state.withLock { $0.cachedFormatDescription } == nil)
      #expect(renderer.formatDescription(for: buffer, generation: firstGeneration) == nil)

      let second = try #require(
        renderer.formatDescription(for: buffer, generation: secondGeneration)
      )
      #expect(first !== second)
      #expect(CMVideoFormatDescriptionMatchesImageBuffer(second, imageBuffer: buffer))

      // Simulate a delayed callback from the superseded generation after the
      // successor has already populated its cache.
      #expect(renderer.formatDescription(for: buffer, generation: firstGeneration) == nil)
      let finalState = renderer.state.withLock { $0 }
      #expect(finalState.cachedFormatDescription?.description === second)
      expectNoDifference(finalState.cachedFormatDescription?.generation, secondGeneration)
      expectNoDifference(finalState.formatDescriptionCreationCount, UInt64(2))
    }

    @Test
    func `Ten thousand stable frames perform one description creation`() throws {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let buffer = try makePixelBuffer(width: 1920, height: 1080)
      let generation = renderer.state.withLock { $0.renderGeneration }
      let first = try #require(
        renderer.formatDescription(for: buffer, generation: generation)
      )

      var exactCacheHits = 0
      for _ in 1..<10000
        where renderer.formatDescription(for: buffer, generation: generation) === first {
        exactCacheHits += 1
      }

      expectNoDifference(exactCacheHits, 9999)
      expectNoDifference(
        renderer.state.withLock { $0.formatDescriptionCreationCount },
        UInt64(1)
      )
    }

    private func makePixelBuffer(
      width: Int,
      height: Int,
      pixelFormat: OSType = kCVPixelFormatType_32BGRA
    )
      throws -> CVPixelBuffer {
      let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
      ]
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        attributes as CFDictionary,
        &buffer
      )
      expectNoDifference(status, kCVReturnSuccess)
      return try #require(buffer)
    }

    private func sampleCreationStatus(
      buffer: CVPixelBuffer,
      description: CMVideoFormatDescription
    ) -> OSStatus {
      var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
      )
      var sample: CMSampleBuffer?
      return CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescription: description,
        sampleTiming: &timing,
        sampleBufferOut: &sample
      )
    }
  }
}
#endif
