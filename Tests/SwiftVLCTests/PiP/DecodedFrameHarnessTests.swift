#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CLibVLC
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

    private final class CapturedFrame: @unchecked Sendable {
      struct Snapshot: @unchecked Sendable {
        var count: UInt64 = 0
        var latestRGBSum: UInt64?
        var maxRGBSum: UInt64 = 0
      }

      let snapshot = Mutex(Snapshot())

      func record(_ sample: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let rgbSum = Self.rgbSum(of: buffer)
        snapshot.withLock {
          $0.count &+= 1
          $0.latestRGBSum = rgbSum
          if let rgbSum {
            $0.maxRGBSum = max($0.maxRGBSum, rgbSum)
          }
        }
      }

      private static func rgbSum(of buffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
          return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var sum: UInt64 = 0
        for row in 0..<height {
          let pixels = baseAddress
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
          for column in 0..<width {
            let offset = column * 4
            sum &+= UInt64(pixels[offset])
            sum &+= UInt64(pixels[offset + 1])
            sum &+= UInt64(pixels[offset + 2])
          }
        }
        return sum
      }
    }

    private final class CapturingHarness {
      let layer: AVSampleBufferDisplayLayer
      let renderer: PixelBufferRenderer
      let registration: DirectPiPVideoCallbackRegistration
      let capture: CapturedFrame

      @MainActor
      init(attachedTo player: Player) {
        layer = AVSampleBufferDisplayLayer()
        capture = CapturedFrame()
        let capture = capture
        renderer = PixelBufferRenderer(
          displayLayer: layer,
          displayLayerAPI: PixelBufferDisplayLayerAPI(
            status: { _ in .rendering },
            requiresFlush: { _ in false },
            flush: { _ in },
            isReadyForMoreMediaData: { _ in true },
            enqueue: { _, sample in capture.record(sample) }
          )
        )
        registration = DirectPiPVideoCallbackRegistration(renderer: renderer)
        player.claimDirectPiPVideoCallbacks(registration)
      }

      var frameCount: UInt64 {
        capture.snapshot.withLock { $0.count }
      }

      var maxRGBSum: UInt64 {
        capture.snapshot.withLock { $0.maxRGBSum }
      }

      func rgbSum() -> UInt64? {
        capture.snapshot.withLock { $0.latestRGBSum }
      }
    }

    private enum SubtitleSnapshotMatch {
      case exactTexts([String])
      case containingText(String)

      func matches(_ snapshot: TextSubtitleSnapshot) -> Bool {
        switch self {
        case .exactTexts(let texts):
          snapshot.regions.map(\.text) == texts
        case .containingText(let text):
          snapshot.regions.contains { $0.text.contains(text) }
        }
      }
    }

    /// Captures one real decoder snapshot through the same vmem path used by
    /// direct PiP. The long sidecar cues and sparse video keep the cue active
    /// while libVLC discovers and explicitly selects the subtitle track.
    private func captureSubtitleSnapshot(
      sidecarURL: URL,
      matching match: SubtitleSnapshotMatch
    )
      async throws -> TextSubtitleSnapshot {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = Harness(attachedTo: player)
      let stream = try player.textSubtitleStream()
      let snapshots = Mutex<[TextSubtitleSnapshot]>([])
      let collector = Task.detached { @Sendable in
        for await snapshot in stream {
          snapshots.withLock { $0.append(snapshot) }
        }
      }

      do {
        try #require(
          await poll(timeout: .seconds(5), until: {
            snapshots.withLock { values in
              values.count == 1 && values[0].regions.isEmpty
            }
          }),
          "the stream did not replay its initial empty presentation"
        )

        let media = try Media(url: TestMedia.sparseURL)
        try media.addSlave(from: sidecarURL, type: .subtitle)
        player.load(media)
        try player.play()

        try #require(
          await poll(timeout: .seconds(10), until: {
            !player.subtitleTracks.isEmpty
          }),
          "the sidecar subtitle track was not discovered"
        )
        let subtitleTrack: Track = try #require(
          player.subtitleTracks.first,
          "the discovered sidecar subtitle track disappeared before selection"
        )
        player.selectedSubtitleTrack = subtitleTrack

        let capturedExpectedSnapshot = try await poll(timeout: .seconds(30), until: {
          harness.drained > 0
            && snapshots.withLock { $0.contains(where: match.matches) }
        })
        let observedRegionTexts = snapshots.withLock { values in
          values.map { $0.regions.map(\.text) }
        }
        try #require(
          capturedExpectedSnapshot,
          Comment(
            rawValue: "the selected sidecar did not produce its expected decoded snapshot; "
              + "observed region texts: \(observedRegionTexts)"
          )
        )
        let snapshot = try #require(
          snapshots.withLock { $0.first(where: match.matches) },
          "the expected decoded snapshot disappeared from the collector"
        )

        collector.cancel()
        await collector.value
        await player.shutdown()
        return snapshot
      } catch {
        collector.cancel()
        await collector.value
        await player.shutdown()
        throw error
      }
    }

    private func webVTTPlacement(in region: TextSubtitleRegion) -> WebVTTPlacement? {
      guard case .webVTT(let placement) = region.placement else { return nil }
      return placement
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

    @Test(.timeLimit(.minutes(2)))
    func `Direct PiP buffers include VLC subtitle blending`() async throws {
      let baselinePlayer = Player(instance: TestInstance.makeVideoDecoding())
      let baselineHarness = CapturingHarness(attachedTo: baselinePlayer)
      try baselinePlayer.play(url: TestMedia.twosecURL)
      defer { baselinePlayer.stop() }
      try #require(
        await poll(timeout: .seconds(30), until: { baselineHarness.frameCount > 2 }),
        "no baseline video frames reached the direct PiP renderer"
      )
      let baseline = try #require(baselineHarness.rgbSum())
      baselinePlayer.stop()

      let subtitlePlayer = Player(instance: TestInstance.makeVideoDecoding())
      let subtitleHarness = CapturingHarness(attachedTo: subtitlePlayer)
      let media = try Media(url: TestMedia.twosecURL)
      try media.addSlave(from: TestMedia.subtitleURL, type: .subtitle)
      subtitlePlayer.load(media)
      try subtitlePlayer.play()
      defer { subtitlePlayer.stop() }
      try #require(
        await poll(timeout: .seconds(10), until: {
          !subtitlePlayer.subtitleTracks.isEmpty
        }),
        "the sidecar subtitle track was not discovered"
      )
      subtitlePlayer.selectedSubtitleTrack = subtitlePlayer.subtitleTracks.first
      try #require(
        await poll(timeout: .seconds(30), until: {
          subtitleHarness.frameCount > 2
            && subtitleHarness.rgbSum().map { $0 > baseline + 10000 } == true
        }),
        "the selected VLC subtitle was not blended into direct PiP's video buffers"
      )
    }

    @Test(
      .enabled(
        if: swiftvlc_subtitle_text_snapshot_callback_available(),
        "Requires the patched libVLC text-subtitle snapshot ABI"
      ),
      .timeLimit(.minutes(2))
    )
    func `Text subtitle stream captures mov_text as automatic regions without blending`() async throws {
      let baselinePlayer = Player(instance: TestInstance.makeVideoDecoding())
      let baselineHarness = CapturingHarness(attachedTo: baselinePlayer)
      try baselinePlayer.play(url: TestMedia.twosecURL)
      try #require(
        await poll(timeout: .seconds(30), until: { baselineHarness.frameCount > 2 }),
        "no subtitle-free baseline frames reached the direct renderer"
      )
      let baselineMax = baselineHarness.maxRGBSum
      await baselinePlayer.shutdown()

      // Positive control: the fixture's default embedded text track really is
      // selected and blended when custom presentation is not enabled.
      let nativePlayer = Player(instance: TestInstance.makeVideoDecoding())
      let nativeHarness = CapturingHarness(attachedTo: nativePlayer)
      try nativePlayer.play(url: TestMedia.internalSubtitlesURL)
      try #require(
        await poll(timeout: .seconds(10), until: {
          !nativePlayer.subtitleTracks.isEmpty
        }),
        "the embedded text track was not discovered for native rendering"
      )
      nativePlayer.selectedSubtitleTrack = nativePlayer.subtitleTracks.first
      try #require(
        await poll(timeout: .seconds(30), until: {
          nativeHarness.maxRGBSum > baselineMax + 10000
        }),
        "the embedded text track was not blended by native subtitle rendering"
      )
      await nativePlayer.shutdown()

      let capturePlayer = Player(instance: TestInstance.makeVideoDecoding())
      let captureHarness = CapturingHarness(attachedTo: capturePlayer)
      let stream = try capturePlayer.textSubtitleStream()
      let snapshots = Mutex<[TextSubtitleSnapshot]>([])
      let collector = Task.detached { @Sendable in
        for await snapshot in stream {
          snapshots.withLock { $0.append(snapshot) }
          if snapshots.withLock({ $0.count >= 4 }) {
            break
          }
        }
      }

      // Consume the replayed empty snapshot before playback. With newest-one
      // buffering, starting first could legitimately replace it with cue one.
      try #require(
        await poll(timeout: .seconds(5), until: {
          snapshots.withLock { values in
            values.count == 1 && values[0].regions.isEmpty
          }
        }),
        "the stream did not replay its initial empty presentation"
      )

      try capturePlayer.play(url: TestMedia.internalSubtitlesURL)
      try #require(
        await poll(timeout: .seconds(10), until: {
          !capturePlayer.subtitleTracks.isEmpty
        }),
        "the embedded text track was not discovered for capture"
      )
      capturePlayer.selectedSubtitleTrack = capturePlayer.subtitleTracks.first
      // Track discovery necessarily happens after playback starts. A fast host
      // can still activate the 0-1 second cue; a slower one begins with the
      // 1-2 second cue. In either case assert every cue displayed after
      // selection, followed by its ordered clear.
      let acceptedTexts = [
        ["", "Hello, SwiftVLC!", "Testing subtitles.", ""],
        ["", "Testing subtitles.", ""]
      ]
      let receivedExpectedSnapshots = try await poll(timeout: .seconds(30), until: {
        snapshots.withLock { acceptedTexts.contains($0.map(\.text)) }
      })
      let receivedSnapshots = snapshots.withLock { $0 }
      let receivedTexts = receivedSnapshots.map(\.text)
      try #require(
        receivedExpectedSnapshots,
        "expected one of \(acceptedTexts), received \(receivedTexts)"
      )
      let capturedRegions = receivedSnapshots.flatMap(\.regions)
      try #require(!capturedRegions.isEmpty, "the mov_text track produced no text regions")
      #expect(
        capturedRegions.allSatisfy { $0.placement == .automatic },
        "mov_text geometry must not be reported as WebVTT placement"
      )
      try #require(
        await poll(timeout: .seconds(30), until: { captureHarness.frameCount > 2 }),
        "no capture-enabled frames reached the direct renderer"
      )

      collector.cancel()
      await collector.value
      await capturePlayer.shutdown()

      #expect(
        captureHarness.maxRGBSum == baselineMax,
        "captured semantic text was still blended into the direct video buffers"
      )
    }

    @Test(
      .enabled(
        if: swiftvlc_subtitle_text_snapshot_callback_available(),
        "Requires the patched libVLC text-subtitle snapshot ABI"
      ),
      .timeLimit(.minutes(2))
    )
    func `WebVTT decoder preserves ordered placement provenance`() async throws {
      let snapshot = try await captureSubtitleSnapshot(
        sidecarURL: TestMedia.webVTTPlacementURL,
        matching: .exactTexts([
          "default cue",
          "positioned cue",
          "vertical cue",
          "start auto-position cue",
          "end auto-position cue",
          "non-finite cue",
          "invalid syntax cue"
        ])
      )
      let regions = snapshot.regions
      #expect(regions.map(\.text) == [
        "default cue",
        "positioned cue",
        "vertical cue",
        "start auto-position cue",
        "end auto-position cue",
        "non-finite cue",
        "invalid syntax cue"
      ])

      let defaultPlacement = try #require(webVTTPlacement(in: regions[0]))
      let positionedPlacement = try #require(webVTTPlacement(in: regions[1]))
      let verticalPlacement = try #require(webVTTPlacement(in: regions[2]))
      let startPlacement = try #require(webVTTPlacement(in: regions[3]))
      let endPlacement = try #require(webVTTPlacement(in: regions[4]))
      let nonFinitePlacement = try #require(webVTTPlacement(in: regions[5]))
      let invalidSyntaxPlacement = try #require(webVTTPlacement(in: regions[6]))

      #expect(abs(defaultPlacement.horizontalPosition - 0.5) < 0.001)
      #expect(abs(defaultPlacement.verticalPosition - 1.0) < 0.001)
      #expect(defaultPlacement.horizontalAnchor == .center)
      #expect(defaultPlacement.verticalAnchor == .bottom)
      #expect(defaultPlacement.maximumWidth == nil)
      #expect(defaultPlacement.maximumHeight == nil)
      #expect(defaultPlacement.textAlignment == .center)
      #expect(defaultPlacement.writingDirection == .horizontal)

      #expect(abs(positionedPlacement.horizontalPosition - 0.15) < 0.001)
      #expect(abs(positionedPlacement.verticalPosition - 0.20) < 0.001)
      #expect(positionedPlacement.horizontalAnchor == .left)
      #expect(positionedPlacement.verticalAnchor == .top)
      #expect(abs((positionedPlacement.maximumWidth ?? 0) - 0.45) < 0.001)
      #expect(positionedPlacement.maximumHeight == nil)
      #expect(positionedPlacement.textAlignment == .left)
      #expect(positionedPlacement.writingDirection == .horizontal)

      #expect(abs(verticalPlacement.horizontalPosition - 0.70) < 0.001)
      #expect(abs(verticalPlacement.verticalPosition - 0.80) < 0.001)
      #expect(verticalPlacement.horizontalAnchor == .right)
      #expect(verticalPlacement.verticalAnchor == .bottom)
      #expect(verticalPlacement.maximumWidth == nil)
      #expect(abs((verticalPlacement.maximumHeight ?? 0) - 0.30) < 0.001)
      #expect(verticalPlacement.textAlignment == .right)
      #expect(verticalPlacement.writingDirection == .verticalGrowingLeft)

      #expect(abs(startPlacement.horizontalPosition - 0.5) < 0.001)
      #expect(startPlacement.horizontalAnchor == .left)
      #expect(abs((startPlacement.maximumWidth ?? 0) - 0.25) < 0.001)
      #expect(startPlacement.textAlignment == .left)

      #expect(abs(endPlacement.horizontalPosition - 0.5) < 0.001)
      #expect(endPlacement.horizontalAnchor == .right)
      #expect(abs((endPlacement.maximumWidth ?? 0) - 0.25) < 0.001)
      #expect(endPlacement.textAlignment == .right)

      for invalidPlacement in [nonFinitePlacement, invalidSyntaxPlacement] {
        #expect(abs(invalidPlacement.horizontalPosition - 0.5) < 0.001)
        #expect(abs(invalidPlacement.verticalPosition - 1.0) < 0.001)
        #expect(invalidPlacement.horizontalAnchor == .center)
        #expect(invalidPlacement.verticalAnchor == .bottom)
        #expect(invalidPlacement.maximumWidth == nil)
        #expect(invalidPlacement.maximumHeight == nil)
      }
    }

    @Test(
      .enabled(
        if: swiftvlc_subtitle_text_snapshot_callback_available(),
        "Requires the patched libVLC text-subtitle snapshot ABI"
      ),
      .timeLimit(.minutes(2))
    )
    func `WebVTT size one hundred remains in region while smaller size leaves`() async throws {
      let snapshot = try await captureSubtitleSnapshot(
        sidecarURL: TestMedia.webVTTRegionURL,
        matching: .exactTexts(["region cue", "explicit size cue", "smaller size cue"])
      )
      let region = try #require(snapshot.regions.first { $0.text == "region cue" })
      let regionPlacement = try #require(webVTTPlacement(in: region))

      #expect(abs(regionPlacement.horizontalPosition - 0.10) < 0.001)
      #expect(abs(regionPlacement.verticalPosition - 0.20) < 0.001)
      #expect(abs((regionPlacement.maximumWidth ?? 0) - 0.40) < 0.001)
      #expect(abs((regionPlacement.maximumHeight ?? 0) - 0.1599) < 0.001)
      #expect(regionPlacement.horizontalAnchor == .left)
      #expect(regionPlacement.verticalAnchor == .top)

      let explicitSizeRegion = try #require(
        snapshot.regions.first { $0.text == "explicit size cue" }
      )
      let explicitSizePlacement = try #require(webVTTPlacement(in: explicitSizeRegion))

      #expect(abs(explicitSizePlacement.horizontalPosition - 0.10) < 0.001)
      #expect(abs(explicitSizePlacement.verticalPosition - 0.20) < 0.001)
      #expect(abs((explicitSizePlacement.maximumWidth ?? 0) - 0.40) < 0.001)
      #expect(abs((explicitSizePlacement.maximumHeight ?? 0) - 0.1599) < 0.001)
      #expect(explicitSizePlacement.horizontalAnchor == .left)
      #expect(explicitSizePlacement.verticalAnchor == .top)

      let smallerSizeRegion = try #require(
        snapshot.regions.first { $0.text == "smaller size cue" }
      )
      let smallerSizePlacement = try #require(webVTTPlacement(in: smallerSizeRegion))

      #expect(abs(smallerSizePlacement.horizontalPosition - 0.5) < 0.001)
      #expect(abs(smallerSizePlacement.verticalPosition - 1.0) < 0.001)
      #expect(abs((smallerSizePlacement.maximumWidth ?? 0) - 0.40) < 0.001)
      #expect(smallerSizePlacement.maximumHeight == nil)
      #expect(smallerSizePlacement.horizontalAnchor == .center)
      #expect(smallerSizePlacement.verticalAnchor == .bottom)
    }

    @Test(
      .enabled(
        if: swiftvlc_subtitle_text_snapshot_callback_available(),
        "Requires the patched libVLC text-subtitle snapshot ABI"
      ),
      .timeLimit(.minutes(2))
    )
    func `SRT decoder always reports automatic placement`() async throws {
      let snapshot = try await captureSubtitleSnapshot(
        sidecarURL: TestMedia.automaticSRTURL,
        matching: .containingText("SRT automatic")
      )

      try #require(snapshot.regions.contains { $0.text.contains("SRT automatic") })
      #expect(snapshot.regions.allSatisfy { $0.placement == .automatic })
    }

    @Test(
      .enabled(
        if: swiftvlc_subtitle_text_snapshot_callback_available(),
        "Requires the patched libVLC text-subtitle snapshot ABI"
      ),
      .timeLimit(.minutes(2))
    )
    func `Positioned TTML decoder still reports automatic placement`() async throws {
      let snapshot = try await captureSubtitleSnapshot(
        sidecarURL: TestMedia.positionedTTMLURL,
        matching: .containingText("TTML automatic")
      )

      try #require(snapshot.regions.contains { $0.text.contains("TTML automatic") })
      #expect(snapshot.regions.allSatisfy { $0.placement == .automatic })
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
      let harness = CapturingHarness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)
      try #require(
        await poll(timeout: .seconds(30), until: { harness.frameCount > 0 }),
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
    /// Asserts on the capture sink's frame count, which advances only after a
    /// converted sample reaches the deterministic headless display boundary.
    /// The first version of this test compared `formatDescriptionCreationCount`
    /// against a baseline, which is monotonic and settles at one for a steady
    /// stream — so `>= baseline` held whether or not a single frame arrived
    /// after the seek. It was a no-op.
    @Test(.timeLimit(.minutes(2)))
    func `Frames continue to arrive after a seek`() async throws {
      let player = Player(instance: TestInstance.makeVideoDecoding())
      let harness = CapturingHarness(attachedTo: player)
      defer { player.stop() }

      try player.play(url: TestMedia.testMP4URL)
      try #require(
        await poll(timeout: .seconds(30), until: { harness.frameCount > 0 }),
        "no frame was delivered before the seek"
      )
      try #require(
        await poll(timeout: .seconds(20), until: { player.isSeekable }),
        "the fixture never became seekable"
      )

      try player.seek(to: .milliseconds(500))

      // Baseline taken *after* the seek is issued, so nothing counted here can
      // predate it.
      let baseline = harness.frameCount
      try #require(
        await poll(timeout: .seconds(20), until: { harness.frameCount > baseline }),
        "no frame was delivered after the seek; conversion stopped at the pipeline refill"
      )
    }
  }
}
#endif
