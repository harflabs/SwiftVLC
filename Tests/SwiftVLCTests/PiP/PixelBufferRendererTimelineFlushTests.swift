#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing

/// The direct renderer dates every sample with the control timebase's time as
/// it is submitted, and the layer presents in timestamp order. Moving the
/// timebase back (a PiP skip, a seek, a resynchronisation) can therefore leave
/// a queued sample dated in the future, where it holds every later sample
/// until the timebase catches up — a frozen picture for the whole distance
/// moved, with audio running. Nothing on the synchronous submission path ever
/// flushed for that: a layer that stopped accepting frames kept refusing them
/// for as long as the hold lasted.
extension Integration {
  struct PixelBufferRendererTimelineFlushTests {
    private enum Event: Equatable {
      case flush
      case enqueue(seconds: Int64)
    }

    private final class Display: @unchecked Sendable {
      struct Values {
        var events: [Event] = []
        var isReady = true
        var becomesReadyOnFlush = false
        var now: ContinuousClock.Instant = .now
      }

      let values = Mutex(Values())

      var api: PixelBufferDisplayLayerAPI {
        PixelBufferDisplayLayerAPI(
          status: { _ in .rendering },
          requiresFlush: { _ in false },
          flush: { _ in
            self.values.withLock {
              $0.events.append(.flush)
              if $0.becomesReadyOnFlush {
                $0.isReady = true
              }
            }
          },
          isReadyForMoreMediaData: { _ in self.values.withLock { $0.isReady } },
          enqueue: { _, sample in
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).value
            self.values.withLock { $0.events.append(.enqueue(seconds: seconds)) }
          }
        )
      }

      var events: [Event] {
        values.withLock { $0.events }
      }

      func advance(by duration: Duration) {
        values.withLock { $0.now = $0.now.advanced(by: duration) }
      }
    }

    private func makeRenderer(
      _ display: Display,
      layer: AVSampleBufferDisplayLayer
    ) -> PixelBufferRenderer {
      PixelBufferRenderer(
        displayLayer: layer,
        displayLayerAPI: display.api,
        stallFlushInterval: .milliseconds(300),
        currentInstant: { display.values.withLock { $0.now } }
      )
    }

    private func submit(
      seconds: Int64,
      to renderer: PixelBufferRenderer,
      layer: AVSampleBufferDisplayLayer
    )
      throws -> Bool {
      var buffer: CVPixelBuffer?
      #expect(
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
          == kCVReturnSuccess
      )
      let pixelBuffer = try #require(buffer)
      var description: CMVideoFormatDescription?
      #expect(
        CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: pixelBuffer,
          formatDescriptionOut: &description
        ) == noErr
      )
      var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: CMTime(value: seconds, timescale: 1),
        decodeTimeStamp: .invalid
      )
      var sample: CMSampleBuffer?
      #expect(
        try CMSampleBufferCreateReadyWithImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: pixelBuffer,
          formatDescription: #require(description),
          sampleTiming: &timing,
          sampleBufferOut: &sample
        ) == noErr
      )
      return try renderer.enqueueSynchronously(
        #require(sample),
        generation: 0,
        on: layer,
        playbackGeneration: 0,
        voutGeneration: 1
      )
    }

    @Test
    func `A sample dated before its queued predecessor flushes the layer first`() throws {
      let display = Display()
      let layer = AVSampleBufferDisplayLayer()
      let renderer = makeRenderer(display, layer: layer)

      #expect(try submit(seconds: 100, to: renderer, layer: layer))
      #expect(try submit(seconds: 101, to: renderer, layer: layer))
      // The control timebase was moved back fifteen seconds.
      #expect(try submit(seconds: 86, to: renderer, layer: layer))
      #expect(try submit(seconds: 87, to: renderer, layer: layer))

      #expect(
        display.events == [
          .enqueue(seconds: 100),
          .enqueue(seconds: 101),
          .flush,
          .enqueue(seconds: 86),
          .enqueue(seconds: 87)
        ],
        "the sample queued before the move would hold the picture until the timebase caught up"
      )
      #expect(renderer.enqueueState.withLock { $0.timelineFlushCount } == 1)
    }

    /// A paused timebase dates every sample alike; scrubbing while paused must
    /// not flush away the frame it just showed.
    @Test
    func `Samples sharing a timestamp never flush`() throws {
      let display = Display()
      let layer = AVSampleBufferDisplayLayer()
      let renderer = makeRenderer(display, layer: layer)

      #expect(try submit(seconds: 40, to: renderer, layer: layer))
      #expect(try submit(seconds: 40, to: renderer, layer: layer))
      #expect(try submit(seconds: 40, to: renderer, layer: layer))

      #expect(!display.events.contains(.flush))
    }

    @Test
    func `A layer that refuses every frame for the stall interval is flushed once`() throws {
      let display = Display()
      let layer = AVSampleBufferDisplayLayer()
      let renderer = makeRenderer(display, layer: layer)

      #expect(try submit(seconds: 1, to: renderer, layer: layer))
      display.values.withLock {
        $0.isReady = false
        $0.becomesReadyOnFlush = true
      }

      // Ordinary backpressure: refused, and nothing flushed.
      #expect(try !submit(seconds: 2, to: renderer, layer: layer))
      display.advance(by: .milliseconds(200))
      #expect(try !submit(seconds: 3, to: renderer, layer: layer))
      #expect(!display.events.contains(.flush))

      // Still refusing past the bound, with frames still arriving.
      display.advance(by: .milliseconds(150))
      #expect(try submit(seconds: 4, to: renderer, layer: layer))

      #expect(
        display.events == [.enqueue(seconds: 1), .flush, .enqueue(seconds: 4)]
      )
      #expect(renderer.enqueueState.withLock { $0.stallFlushCount } == 1)
    }

    @Test
    func `A stalled layer is flushed once per interval, not once per frame`() throws {
      let display = Display()
      let layer = AVSampleBufferDisplayLayer()
      let renderer = makeRenderer(display, layer: layer)
      display.values.withLock { $0.isReady = false }

      #expect(try !submit(seconds: 1, to: renderer, layer: layer))
      display.advance(by: .milliseconds(350))
      for seconds in Int64(2)...6 {
        #expect(try !submit(seconds: seconds, to: renderer, layer: layer))
        display.advance(by: .milliseconds(40))
      }

      #expect(display.events == [.flush])

      display.advance(by: .milliseconds(300))
      #expect(try !submit(seconds: 7, to: renderer, layer: layer))
      #expect(display.events == [.flush, .flush])
    }

    @Test
    func `An accepted frame ends the stall measurement`() throws {
      let display = Display()
      let layer = AVSampleBufferDisplayLayer()
      let renderer = makeRenderer(display, layer: layer)

      display.values.withLock { $0.isReady = false }
      #expect(try !submit(seconds: 1, to: renderer, layer: layer))
      display.advance(by: .milliseconds(200))
      display.values.withLock { $0.isReady = true }
      #expect(try submit(seconds: 2, to: renderer, layer: layer))

      // A later refusal starts a new measurement rather than inheriting the
      // 200 ms already spent.
      display.values.withLock { $0.isReady = false }
      display.advance(by: .milliseconds(200))
      #expect(try !submit(seconds: 3, to: renderer, layer: layer))
      display.advance(by: .milliseconds(200))
      #expect(try !submit(seconds: 4, to: renderer, layer: layer))

      #expect(!display.events.contains(.flush))
    }
  }
}
#endif
