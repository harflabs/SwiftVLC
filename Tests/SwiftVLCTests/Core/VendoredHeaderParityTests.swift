@testable import SwiftVLC
import CLibVLC
import Testing

/// The xcframework ships headers from `Sources/CLibVLC/include`, **not** from
/// the patched VLC source tree — `build-libvlc.sh` passes that directory to
/// `xcodebuild -create-xcframework -headers`.
///
/// So an engine patch that changes a public libVLC header has to change the
/// vendored copy too, or the change reaches the compiled library and never
/// reaches consumers. Patch 0015 did exactly that: the built `libvlc.a`
/// populated `media_player_media_stopping.reason`, while every shipped header
/// still declared a struct without the field, leaving it invisible to Swift.
///
/// Nothing caught it. The patch applied, the engine compiled, and a runtime
/// probe passed — because the probe compiled against the VLC source headers
/// (`-I .build-libvlc/vlc/include`) rather than the ones actually shipped.
///
/// These tests reference the symbols through `CLibVLC`, so they fail to
/// compile if the vendored header loses them.
@Suite(.tags(.logic))
struct VendoredHeaderParityTests {
  /// Values must match `vlc_player_media_stopping_reason` in the engine, which
  /// `lib/media_player.c` static_asserts. Pinning them here means a divergence
  /// introduced on the vendored side alone still fails.
  @Test
  func `The stopping-reason enum is declared with upstream's values`() {
    #expect(libvlc_stopping_reason_error.rawValue == 0)
    #expect(libvlc_stopping_reason_eos.rawValue == 1)
    #expect(libvlc_stopping_reason_user.rawValue == 2)
  }

  /// The field the whole patch exists to deliver. Without it in the vendored
  /// header this does not compile, which is the point.
  @Test
  func `The media-stopping event carries a reason Swift can read`() {
    var event = libvlc_event_t()
    event.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
    #expect(event.u.media_player_media_stopping.reason == libvlc_stopping_reason_eos)

    event.u.media_player_media_stopping.reason = libvlc_stopping_reason_user
    #expect(event.u.media_player_media_stopping.reason == libvlc_stopping_reason_user)
  }

  /// Patch 0020 extends the existing encountered-error event rather than
  /// creating a wrapper-only guess. Referencing every value and the union
  /// field here keeps the shipped header aligned with that engine ABI.
  @Test
  func `The encountered-error event carries a playback failure kind`() {
    #expect(libvlc_playback_failure_unknown.rawValue == 0)
    #expect(libvlc_playback_failure_source.rawValue == 1)
    #expect(libvlc_playback_failure_demux.rawValue == 2)
    #expect(libvlc_playback_failure_decoder.rawValue == 3)
    #expect(libvlc_playback_failure_renderer.rawValue == 4)
    #expect(libvlc_playback_failure_output.rawValue == 5)

    var event = libvlc_event_t()
    event.u.media_player_encountered_error.failure = libvlc_playback_failure_renderer
    #expect(
      event.u.media_player_encountered_error.failure == libvlc_playback_failure_renderer
    )
  }

  /// Extension version 2 uses a separate retained-media snapshot so the
  /// version-1 layout stays ABI-compatible. Referencing both types keeps the
  /// engine and shipped headers from silently diverging at this boundary.
  @Test
  func `The playback snapshot is distinct from the version one layout`() {
    let legacySize = MemoryLayout<swiftvlc_media_player_media_length_snapshot_t>.size
    var snapshot = swiftvlc_media_player_playback_snapshot_t()
    snapshot.length = 2000
    snapshot.time = 750
    snapshot.seekable = true

    #expect(legacySize < MemoryLayout.size(ofValue: snapshot))
    #expect(snapshot.length == 2000)
    #expect(snapshot.time == 750)
    #expect(snapshot.seekable)
  }

  /// Patch 0027 adds a request-correlated terminal event and submission
  /// result. Referencing both through CLibVLC catches a rebuilt engine paired
  /// with stale vendored headers before it reaches an application link.
  @Test
  func `The strict frame-step ABI is visible through the shipped headers`() {
    #expect(swiftvlc_next_frame_request_accepted.rawValue == 0)
    #expect(swiftvlc_next_frame_request_busy.rawValue == 1)
    #expect(swiftvlc_next_frame_request_invalid.rawValue == 2)
    #expect(swiftvlc_next_frame_request_unavailable.rawValue == 3)

    var event = libvlc_event_t()
    event.type = Int32(libvlc_MediaPlayerFrameStepCompleted.rawValue)
    event.u.media_player_frame_step_completed.request_id = 42
    event.u.media_player_frame_step_completed.status = 0
    event.u.media_player_frame_step_completed.time_us = 1_250_000
    event.u.media_player_frame_step_completed.position = 0.5

    #expect(event.type == Int32(libvlc_MediaPlayerFrameStepCompleted.rawValue))
    #expect(event.u.media_player_frame_step_completed.request_id == 42)
    #expect(event.u.media_player_frame_step_completed.status == 0)
    #expect(event.u.media_player_frame_step_completed.time_us == 1_250_000)
    #expect(event.u.media_player_frame_step_completed.position == 0.5)
  }

  /// Patch 0031 appends an effective-rate event without growing or reordering
  /// libVLC's released event envelope.
  @Test
  func `The effective playback-rate event is visible through shipped headers`() {
    #expect(
      libvlc_MediaPlayerRateChanged.rawValue
        == libvlc_MediaPlayerFrameStepCompleted.rawValue + 1
    )

    var event = libvlc_event_t()
    event.type = Int32(libvlc_MediaPlayerRateChanged.rawValue)
    event.u.media_player_rate_changed.new_rate = 1.25

    #expect(MemoryLayout.size(ofValue: event) == 40)
    #expect(event.u.media_player_rate_changed.new_rate == 1.25)
  }

  /// Patch 0030 adds a distinct callback/setter pair so the v4 function-pointer
  /// ABI can never silently change when source picture timing is enabled.
  @Test
  func `The native picture timestamp callback is additive in shipped headers`() {
    let callback: swiftvlc_video_display_status_v2_cb? = nil
    let setter = swiftvlc_libvlc_video_set_callbacks_atomic_v2

    #expect(callback == nil)
    _ = setter
  }

  /// The engine, weak-link shim, and Swift qualification mapping all exchange
  /// this struct by value. Pinning every flag plus its size/alignment prevents
  /// a reordered vendored declaration from silently corrupting live evidence.
  @Test
  func `The native renderer recovery ABI is visible through the shipped headers`() {
    #expect(swiftvlc_sample_buffer_renderer_current.rawValue == 1 << 0)
    #expect(swiftvlc_sample_buffer_renderer_requires_flush.rawValue == 1 << 1)
    #expect(swiftvlc_sample_buffer_renderer_failed.rawValue == 1 << 2)
    #expect(swiftvlc_sample_buffer_renderer_recovery_in_progress.rawValue == 1 << 3)
    #expect(swiftvlc_sample_buffer_renderer_recovery_sample_available.rawValue == 1 << 4)

    var snapshot = swiftvlc_sample_buffer_renderer_snapshot_t()
    snapshot.abi_version = 1
    snapshot.display_generation = 42
    snapshot.successful_submission_count = 99
    snapshot.permanent_failure_count = 3

    #expect(MemoryLayout.size(ofValue: snapshot) == 136)
    #expect(MemoryLayout.alignment(ofValue: snapshot) == 8)
    #expect(snapshot.abi_version == 1)
    #expect(snapshot.display_generation == 42)
    #expect(snapshot.successful_submission_count == 99)
    #expect(snapshot.permanent_failure_count == 3)
  }

  /// Extension version 10 preserves ordered regions and WebVTT provenance in
  /// a fixed-width record. These layout and symbol checks compile through the
  /// exact headers shipped in the xcframework.
  @Test
  func `The subtitle text snapshot ABI is present in vendored headers`() {
    #expect(swiftvlc_subtitle_text_placement_automatic == 0)
    #expect(swiftvlc_subtitle_text_placement_webvtt == 1)
    #expect(swiftvlc_webvtt_horizontal_anchor_center == 0)
    #expect(swiftvlc_webvtt_horizontal_anchor_left == 1)
    #expect(swiftvlc_webvtt_horizontal_anchor_right == 2)
    #expect(swiftvlc_webvtt_vertical_anchor_center == 0)
    #expect(swiftvlc_webvtt_vertical_anchor_top == 1)
    #expect(swiftvlc_webvtt_vertical_anchor_bottom == 2)
    #expect(swiftvlc_webvtt_text_alignment_center == 0)
    #expect(swiftvlc_webvtt_text_alignment_left == 1)
    #expect(swiftvlc_webvtt_text_alignment_right == 2)
    #expect(swiftvlc_webvtt_writing_direction_horizontal == 0)
    #expect(swiftvlc_webvtt_writing_direction_vertical_growing_left == 1)
    #expect(swiftvlc_webvtt_writing_direction_vertical_growing_right == 2)
    #expect(SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_WIDTH == 1)
    #expect(SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_HEIGHT == 2)

    var placement = swiftvlc_webvtt_placement_t()
    placement.horizontal_position = 0.25
    placement.vertical_position = 0.75
    placement.maximum_width = 0.5
    placement.maximum_height = 0.4
    placement.flags = UInt32(
      SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_WIDTH
        | SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_HEIGHT
    )
    placement.horizontal_anchor = swiftvlc_webvtt_horizontal_anchor_t(
      swiftvlc_webvtt_horizontal_anchor_left
    )
    placement.vertical_anchor = swiftvlc_webvtt_vertical_anchor_t(
      swiftvlc_webvtt_vertical_anchor_bottom
    )
    placement.text_alignment = swiftvlc_webvtt_text_alignment_t(
      swiftvlc_webvtt_text_alignment_right
    )
    placement.writing_direction = swiftvlc_webvtt_writing_direction_t(
      swiftvlc_webvtt_writing_direction_vertical_growing_left
    )

    var region = swiftvlc_subtitle_text_region_t()
    region.placement = swiftvlc_subtitle_text_placement_kind_t(
      swiftvlc_subtitle_text_placement_webvtt
    )
    region.webvtt = placement

    #expect(MemoryLayout<swiftvlc_webvtt_placement_t>.size == 36)
    #expect(MemoryLayout<swiftvlc_webvtt_placement_t>.offset(of: \.flags) == 16)
    #expect(MemoryLayout<swiftvlc_webvtt_placement_t>.offset(of: \.writing_direction) == 32)
    #expect(MemoryLayout<swiftvlc_subtitle_text_region_t>.size == 48)
    #expect(MemoryLayout<swiftvlc_subtitle_text_region_t>.offset(of: \.placement) == 8)
    #expect(MemoryLayout<swiftvlc_subtitle_text_region_t>.offset(of: \.webvtt) == 12)
    #expect(region.webvtt.horizontal_position == 0.25)
    #expect(region.webvtt.vertical_position == 0.75)

    let callback: swiftvlc_subtitle_text_snapshot_cb = { _, regions, count in
      _ = regions
      _ = count
    }

    _ = callback
    _ = swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback
    _ = swiftvlc_media_player_set_subtitle_text_snapshot_callback_if_available
    #expect(
      swiftvlc_subtitle_text_snapshot_callback_available()
        == (swiftvlc_libvlc_pip_extensions_version() >= 10)
    )
  }
}
