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

      /// Frames actually delivered to the layer. Unlike `creations`, which
      /// settles at one for a steady stream, this advances per frame — so it
      /// is the only counter that can show whether frames are *still* flowing.
      var drained: UInt64 {
        renderer.enqueueSnapshotForTesting.drainedSampleCount
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

    /// Issue 93 criterion 2: a PiP resize must change the effective work, or
    /// the reason it cannot must be documented.
    ///
    /// This is the assertion that previously needed a device. With real frames
    /// flowing, setting a render size smaller than the source must make the
    /// renderer allocate and convert into a pool at that size — which is the
    /// work reduction the criterion is about. A no-op resize leaves the pool
    /// untouched and fails here.
    @Test(.timeLimit(.minutes(2)))
    func `A smaller render size converts into a smaller pool`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = Harness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)
      try #require(
        await poll(timeout: .seconds(30), until: { harness.drained > 0 }),
        "no frame was delivered before the resize"
      )

      // The source dimensions come from the player, not the renderer: the
      // format callback sets width/height on a separate decode renderer, while
      // this harness holds the display renderer that performs output
      // conversion.
      let source = try #require(player.videoSize, "the player never reported a video size")
      try #require(source.width > 2 && source.height > 2, "the fixture is too small to scale down from")

      let target = CMVideoDimensions(
        width: Int32(source.width / 2),
        height: Int32(source.height / 2)
      )
      harness.renderer.setRenderSize(target)

      try #require(
        await poll(timeout: .seconds(20), until: {
          harness.renderer.state.withLock { $0.renderPoolWidth } == Int(target.width)
        }),
        "frames kept converting at full resolution after the render size shrank"
      )

      let pool = harness.renderer.state.withLock { ($0.renderPoolWidth, $0.renderPoolHeight) }
      #expect(pool.0 == Int(target.width))
      #expect(pool.1 == Int(target.height))
    }

    /// Frames keep arriving across a seek.
    ///
    /// A seek tears down and refills the decoder pipeline. If conversion
    /// stopped there, PiP would freeze on the pre-seek picture — on a device
    /// that looks like a stuck window rather than an error.
    ///
    /// Asserts on `drainedSampleCount`, which advances per delivered frame.
    /// The first version of this test compared `formatDescriptionCreationCount`
    /// against a baseline, which is monotonic and settles at one for a steady
    /// stream — so `>= baseline` held whether or not a single frame arrived
    /// after the seek. It was a no-op.
    @Test(.timeLimit(.minutes(2)))
    func `Frames continue to arrive after a seek`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = Harness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)
      try #require(
        await poll(timeout: .seconds(30), until: { harness.drained > 0 }),
        "no frame was delivered before the seek"
      )
      try #require(
        await poll(timeout: .seconds(20), until: { player.isSeekable }),
        "the fixture never became seekable"
      )

      try player.seek(to: .milliseconds(500))

      // Baseline taken *after* the seek is issued, so nothing counted here can
      // predate it.
      let baseline = harness.drained
      try #require(
        await poll(timeout: .seconds(20), until: { harness.drained > baseline }),
        "no frame was delivered after the seek; conversion stopped at the pipeline refill"
      )
    }
  }
}
#endif
