#if os(iOS) || os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

extension PixelBufferRenderer {
  /// Returns a description valid for this exact output generation and image
  /// buffer format. Core Media's match operation covers dimensions, pixel
  /// format, bytes-per-row, and every format attachment common to image
  /// buffers (including clean aperture, pixel aspect ratio, color metadata,
  /// and HDR metadata). A stale generation is rejected instead of being
  /// allowed to replace the current generation's cache entry.
  func formatDescription(
    for imageBuffer: CVImageBuffer,
    generation: UInt64
  ) -> CMVideoFormatDescription? {
    state.withLock { state in
      guard state.renderGeneration == generation else { return nil }

      if
        let cached = state.cachedFormatDescription,
        cached.generation == generation,
        CMVideoFormatDescriptionMatchesImageBuffer(
          cached.description,
          imageBuffer: imageBuffer
        ) {
        return cached.description
      }

      // Never leave an incompatible description installed if replacement
      // creation fails. The next valid frame can retry from an empty cache.
      state.cachedFormatDescription = nil

      var description: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &description
      )
      guard status == noErr, let description else { return nil }

      state.cachedFormatDescription = State.CachedFormatDescription(
        generation: generation,
        description: description
      )
      state.formatDescriptionCreationCount &+= 1
      return description
    }
  }
}
#endif
