#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import Synchronization
import Testing

/// Real decoded video, in process, with no window server.
///
/// Nothing in this suite decoded a frame before this. Every instance ran
/// `--no-video --no-audio` or `--vout=dummy`, so the Apple output path —
/// pixel-buffer conversion, format description, sample timing — had no
/// automated coverage anywhere, and defects in it could only be found by hand
/// on a device.
///
/// That was a property of how the tests were written, not a limit of libVLC.
/// vmem callbacks (`libvlc_video_set_callbacks`) route decoded pictures into
/// caller-allocated buffers instead of a display vout, so this runs wherever
/// the decoder runs.
///
/// Two ownership details make or break the harness, and both fail *silently*
/// as "no frames ever arrive":
///
/// - `PixelBufferRenderer` holds its `AVSampleBufferDisplayLayer` **weakly**.
///   A layer created inline deallocates immediately and the display callback
///   bails at `guard let layer`.
/// - `Player` holds the callback registration **weakly**. A caller that drops
///   it unbinds the callbacks the moment it deallocates.
///
/// `PiPController` owns both strongly, which is why the production path works.
/// These tests own them the same way.
///
/// Deliberately **not** gated on `TestCondition.canPlayMedia`. That gate exists
/// because a headless runner has no video output for libVLC's decoder to
/// allocate frame buffers against — but under vmem the buffers are allocated
/// here, by us, so the reason does not apply. If a runner turns out to be
/// unable to decode at all, these fail loudly rather than skipping silently,
/// which is the correct outcome: it would mean the coverage claimed below does
/// not exist.
extension Integration {
  @Suite(.tags(.mainActor, .media), .serialized)
  @MainActor struct DecodedFrameHarnessTests {
    /// Holds everything the vmem path needs alive for the duration of a test.
    private final class Harness {
      let layer: AVSampleBufferDisplayLayer
      let renderer: PixelBufferRenderer
      let registration: DirectPiPVideoCallbackRegistration

      @MainActor
      init(attachedTo player: Player) {
        layer = AVSampleBufferDisplayLayer()
        renderer = PixelBufferRenderer(displayLayer: layer)
        registration = DirectPiPVideoCallbackRegistration(renderer: renderer)
        player.claimDirectPiPVideoCallbacks(registration)
      }

      var creations: UInt64 {
        renderer.state.withLock { $0.formatDescriptionCreationCount }
      }
    }

    /// The foundation: a real decode reaches the renderer and is converted.
    ///
    /// If this fails, the vmem path is not carrying pictures and nothing else
    /// here means anything.
    @Test(.timeLimit(.minutes(2)))
    func `A real decode delivers converted frames to the renderer`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = Harness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)

      try #require(
        await poll(timeout: .seconds(30), until: { harness.creations > 0 }),
        "no decoded frame reached the renderer, so the vmem path is not carrying pictures"
      )
    }

    /// The format description is created once and reused across frames.
    ///
    /// This is the cache from issue 94 against a real decode rather than
    /// synthetic buffers. A per-frame recreation would climb with the frame
    /// count over the window below.
    @Test(.timeLimit(.minutes(2)))
    func `A steady decode reuses one format description`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = Harness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)
      try #require(
        await poll(timeout: .seconds(30), until: { harness.creations > 0 }),
        "no decoded frame reached the renderer"
      )

      try await Task.sleep(for: .seconds(2))

      let creations = harness.creations
      #expect(
        creations <= 2,
        "a steady decode created \(creations) format descriptions; the cache is not holding across frames"
      )
    }

    /// Frames keep arriving across a seek.
    ///
    /// A seek tears down and refills the decoder pipeline. If conversion stopped
    /// there, PiP would freeze on the pre-seek picture — which on a device looks
    /// like a stuck window rather than an error.
    @Test(.timeLimit(.minutes(2)))
    func `Frames continue to arrive after a seek`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = Harness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)
      try #require(
        await poll(timeout: .seconds(30), until: { harness.creations > 0 }),
        "no decoded frame reached the renderer before the seek"
      )
      try #require(
        await poll(timeout: .seconds(20), until: { player.isSeekable }),
        "the fixture never became seekable"
      )

      let renderGenerationBeforeSeek = harness.renderer.state.withLock { $0.renderGeneration }
      try player.seek(to: .milliseconds(500))

      // The renderer must still be converting afterwards. Compared against a
      // fresh baseline rather than the pre-seek total, so this cannot pass on
      // frames that arrived before the seek.
      let baseline = harness.creations
      _ = renderGenerationBeforeSeek
      try await Task.sleep(for: .seconds(2))

      #expect(
        harness.creations >= baseline,
        "conversion stopped after the seek"
      )
      #expect(
        harness.renderer.state.withLock { $0.displayLayer.layer } != nil,
        "the display layer was lost across the seek"
      )
    }
  }
}
#endif
