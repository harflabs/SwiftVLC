#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import Synchronization
import Testing

extension Integration {
  struct PixelBufferRendererTests {
    @Test
    func `Can be created with an AVSampleBufferDisplayLayer`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      let current = renderer.state.withLock { $0.displayLayer.layer }
      #expect(current === layer)
    }

    @Test
    func `setDisplayLayer nil does not crash`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      renderer.setDisplayLayer(nil)
      let current = renderer.state.withLock { $0.displayLayer.layer }
      #expect(current == nil)
    }

    @Test
    func `setTimebase nil does not crash`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      renderer.setTimebase(nil)
      let tb = renderer.state.withLock { $0.timebase }
      #expect(tb == nil)
    }

    @Test
    func `State is initially empty`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      let state = renderer.state.withLock { $0 }
      #expect(state.pool == nil)
      #expect(state.width == 0)
      #expect(state.height == 0)
    }

    @Test
    func `Sendable conformance`() {
      let _: any Sendable.Type = PixelBufferRenderer.self
    }
  }
}

// MARK: - Extended Tests

extension Integration {
  struct PixelBufferRendererExtendedTests {
    @Test
    func `State pool is initially nil`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      let pool = renderer.state.withLock { $0.pool }
      #expect(pool == nil)
    }

    @Test
    func `State width and height are initially zero`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      let (w, h) = renderer.state.withLock { ($0.width, $0.height) }
      #expect(w == 0)
      #expect(h == 0)
    }

    @Test
    func `setDisplayLayer stores weak reference`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      let current = renderer.state.withLock { $0.displayLayer.layer }
      #expect(current === layer)
    }

    @Test
    func `setDisplayLayer nil clears reference`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      renderer.setDisplayLayer(nil)
      let current = renderer.state.withLock { $0.displayLayer.layer }
      #expect(current == nil)
    }

    @Test
    func `setDisplayLayer replaces with new layer`() {
      let layer1 = AVSampleBufferDisplayLayer()
      let layer2 = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer1)

      let before = renderer.state.withLock { $0.displayLayer.layer }
      #expect(before === layer1)

      renderer.setDisplayLayer(layer2)
      let after = renderer.state.withLock { $0.displayLayer.layer }
      #expect(after === layer2)
    }

    @Test
    func `setTimebase stores a real CMTimebase`() throws {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)

      let clock = CMClockGetHostTimeClock()
      var timebase: CMTimebase?
      let status = CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault,
        sourceClock: clock,
        timebaseOut: &timebase
      )
      #expect(status == noErr)
      let tb = try #require(timebase)

      renderer.setTimebase(tb)
      let stored = renderer.state.withLock { $0.timebase }
      #expect(stored != nil)
    }

    @Test
    func `setTimebase nil clears timebase`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)

      let clock = CMClockGetHostTimeClock()
      var timebase: CMTimebase?
      CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault,
        sourceClock: clock,
        timebaseOut: &timebase
      )
      renderer.setTimebase(timebase)
      // Verify it was set
      let before = renderer.state.withLock { $0.timebase }
      #expect(before != nil)

      // Clear it
      renderer.setTimebase(nil)
      let after = renderer.state.withLock { $0.timebase }
      #expect(after == nil)
    }

    @Test
    func `State is Sendable`() {
      let _: any Sendable.Type = PixelBufferRenderer.State.self
    }

    @Test
    func `Multiple setDisplayLayer calls do not crash`() {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      for _ in 0..<20 {
        renderer.setDisplayLayer(AVSampleBufferDisplayLayer())
      }
      renderer.setDisplayLayer(nil)
      renderer.setDisplayLayer(AVSampleBufferDisplayLayer())
      renderer.setDisplayLayer(nil)
      // If we reach here without crashing, the test passes
      let current = renderer.state.withLock { $0.displayLayer.layer }
      #expect(current == nil)
    }

    @Test
    func `Multiple setTimebase calls do not crash`() {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let clock = CMClockGetHostTimeClock()

      for _ in 0..<20 {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
          allocator: kCFAllocatorDefault,
          sourceClock: clock,
          timebaseOut: &tb
        )
        renderer.setTimebase(tb)
      }
      renderer.setTimebase(nil)
      renderer.setTimebase(nil)
      // If we reach here without crashing, the test passes
      let current = renderer.state.withLock { $0.timebase }
      #expect(current == nil)
    }

    @Test
    func `Initial state has all fields at default values`() {
      let layer = AVSampleBufferDisplayLayer()
      let renderer = PixelBufferRenderer(displayLayer: layer)
      let (pool, w, h, tb, stored) = renderer.state.withLock {
        ($0.pool, $0.width, $0.height, $0.timebase, $0.displayLayer.layer)
      }
      #expect(pool == nil)
      #expect(w == 0)
      #expect(h == 0)
      #expect(tb == nil)
      #expect(stored === layer)
    }
  }
}
#endif
