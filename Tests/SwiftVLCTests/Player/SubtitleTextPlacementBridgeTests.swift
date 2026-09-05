@testable import SwiftVLC
import CLibVLC
import Testing

extension Logic {
  @Suite(.tags(.async))
  struct SubtitleTextPlacementBridgeTests {
    @Test
    func `Snapshot preserves ordered regions and flattened text`() {
      let snapshot = TextSubtitleSnapshot(
        regions: [
          TextSubtitleRegion(text: "first"),
          TextSubtitleRegion(text: "second")
        ]
      )

      #expect(snapshot.regions.map(\.text) == ["first", "second"])
      #expect(snapshot.text == "first\nsecond")
      #expect(!snapshot.isEmpty)
      #expect(TextSubtitleSnapshot().isEmpty)
    }

    @Test
    func `Positioned WebVTT cue maps every resolved field`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(16)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      harness.send([
        .webVTT(
          "positioned",
          horizontalPosition: 0.18,
          verticalPosition: 0.72,
          horizontalAnchor: swiftvlc_webvtt_horizontal_anchor_left,
          verticalAnchor: swiftvlc_webvtt_vertical_anchor_top,
          maximumWidth: 0.64,
          maximumHeight: 0.21,
          textAlignment: swiftvlc_webvtt_text_alignment_right,
          writingDirection: swiftvlc_webvtt_writing_direction_vertical_growing_left
        )
      ])

      #expect(
        await values.next()
          == TextSubtitleSnapshot(
            regions: [
              TextSubtitleRegion(
                text: "positioned",
                placement: .webVTT(
                  WebVTTPlacement(
                    horizontalPosition: 0.18,
                    verticalPosition: 0.72,
                    horizontalAnchor: .left,
                    verticalAnchor: .top,
                    maximumWidth: 0.64,
                    maximumHeight: 0.21,
                    textAlignment: .right,
                    writingDirection: .verticalGrowingLeft
                  )
                )
              )
            ]
          )
      )

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Multiple simultaneous WebVTT regions keep native order`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(17)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      harness.send([
        .webVTT(
          "left",
          horizontalPosition: 0.1,
          verticalPosition: 0.9,
          horizontalAnchor: swiftvlc_webvtt_horizontal_anchor_left
        ),
        .webVTT(
          "right",
          horizontalPosition: 0.9,
          verticalPosition: 0.2,
          horizontalAnchor: swiftvlc_webvtt_horizontal_anchor_right,
          verticalAnchor: swiftvlc_webvtt_vertical_anchor_bottom,
          textAlignment: swiftvlc_webvtt_text_alignment_left,
          writingDirection: swiftvlc_webvtt_writing_direction_vertical_growing_right
        )
      ])

      let snapshot = try #require(await values.next())
      #expect(snapshot.text == "left\nright")
      #expect(snapshot.regions.map(\.text) == ["left", "right"])
      #expect(
        snapshot.regions.map(\.placement)
          == [
            .webVTT(
              WebVTTPlacement(
                horizontalPosition: 0.1,
                verticalPosition: 0.9,
                horizontalAnchor: .left
              )
            ),
            .webVTT(
              WebVTTPlacement(
                horizontalPosition: 0.9,
                verticalPosition: 0.2,
                horizontalAnchor: .right,
                textAlignment: .left,
                writingDirection: .verticalGrowingRight
              )
            )
          ]
      )

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `WebVTT default placement remains explicit`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(18)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      harness.send([
        .webVTT(
          "default",
          horizontalPosition: 0.5,
          verticalPosition: 0.96
        )
      ])

      let snapshot = try #require(await values.next())
      #expect(
        snapshot.regions.first?.placement
          == .webVTT(
            WebVTTPlacement(
              horizontalPosition: 0.5,
              verticalPosition: 0.96
            )
          )
      )

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `WebVTT vertical center anchor maps explicitly`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(24)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      harness.send([
        .webVTT(
          "centered",
          horizontalPosition: 0.5,
          verticalPosition: 0.5,
          verticalAnchor: swiftvlc_webvtt_vertical_anchor_center
        )
      ])

      let snapshot = try #require(await values.next())
      #expect(
        snapshot.regions.first?.placement
          == .webVTT(
            WebVTTPlacement(
              horizontalPosition: 0.5,
              verticalPosition: 0.5,
              verticalAnchor: .center
            )
          )
      )

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Non-WebVTT semantic formats always map to automatic`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(19)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      // The discriminator carries provenance. Generic geometry from SRT,
      // TTML, mov_text, or another decoder must not become WebVTT placement.
      harness.send([
        .automatic("SRT", noisyWebVTTPayload: true),
        .automatic("TTML", noisyWebVTTPayload: true),
        .automatic("mov_text", noisyWebVTTPayload: true),
        .automatic("other", noisyWebVTTPayload: true)
      ])

      let snapshot = try #require(await values.next())
      #expect(snapshot.regions.map(\.text) == ["SRT", "TTML", "mov_text", "other"])
      #expect(snapshot.regions.allSatisfy { $0.placement == .automatic })

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Placement-only changes are emitted and exact snapshots deduplicate`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(20)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      let first = NativeSubtitleRegionInput.webVTT(
        "same text",
        horizontalPosition: 0.25,
        verticalPosition: 0.8
      )
      let moved = NativeSubtitleRegionInput.webVTT(
        "same text",
        horizontalPosition: 0.75,
        verticalPosition: 0.8
      )
      harness.send([first])
      harness.send([first])
      harness.send([moved])

      let initial = try #require(await values.next())
      let changed = try #require(await values.next())
      #expect(initial.text == changed.text)
      #expect(initial.regions.first?.placement != changed.regions.first?.placement)

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Unknown or malformed native placement fails closed to automatic`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(21)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      _ = await values.next()

      var nonfinite = NativeSubtitleRegionInput.defaultWebVTTPayload
      nonfinite.horizontal_position = .nan
      var invalidAnchor = NativeSubtitleRegionInput.defaultWebVTTPayload
      invalidAnchor.horizontal_anchor = UInt32.max
      var invalidVerticalAnchor = NativeSubtitleRegionInput.defaultWebVTTPayload
      invalidVerticalAnchor.vertical_anchor = UInt32.max
      var invalidTextAlignment = NativeSubtitleRegionInput.defaultWebVTTPayload
      invalidTextAlignment.text_alignment = UInt32.max
      var invalidWritingDirection = NativeSubtitleRegionInput.defaultWebVTTPayload
      invalidWritingDirection.writing_direction = UInt32.max
      var invalidFlags = NativeSubtitleRegionInput.defaultWebVTTPayload
      invalidFlags.flags = UInt32.max
      harness.send([
        NativeSubtitleRegionInput(
          text: "unknown discriminator",
          placement: UInt32.max,
          webVTT: NativeSubtitleRegionInput.defaultWebVTTPayload
        ),
        NativeSubtitleRegionInput(
          text: "nonfinite",
          placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
          webVTT: nonfinite
        ),
        NativeSubtitleRegionInput(
          text: "invalid anchor",
          placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
          webVTT: invalidAnchor
        ),
        NativeSubtitleRegionInput(
          text: "invalid vertical anchor",
          placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
          webVTT: invalidVerticalAnchor
        ),
        NativeSubtitleRegionInput(
          text: "invalid text alignment",
          placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
          webVTT: invalidTextAlignment
        ),
        NativeSubtitleRegionInput(
          text: "invalid writing direction",
          placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
          webVTT: invalidWritingDirection
        ),
        NativeSubtitleRegionInput(
          text: "invalid flags",
          placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
          webVTT: invalidFlags
        ),
        .webVTT(
          "negative maximum",
          horizontalPosition: 0.5,
          verticalPosition: 0.96,
          maximumWidth: -0.1
        )
      ])

      let snapshot = try #require(await values.next())
      #expect(snapshot.regions.count == 8)
      #expect(snapshot.regions.allSatisfy { $0.placement == .automatic })

      lifetime.initialOwnerDidRelease()
    }
  }
}
