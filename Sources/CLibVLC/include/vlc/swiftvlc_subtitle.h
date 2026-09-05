/*****************************************************************************
 * swiftvlc_subtitle.h: SwiftVLC semantic text-subtitle snapshot ABI
 *****************************************************************************
 * This header intentionally depends only on fixed-width C types so both
 * libVLC's public API and the libvlccore subtitle pipeline share one layout.
 *****************************************************************************/

#ifndef VLC_SWIFTVLC_SUBTITLE_H
#define VLC_SWIFTVLC_SUBTITLE_H 1

#include <stddef.h>
#include <stdint.h>

typedef uint32_t swiftvlc_subtitle_text_placement_kind_t;
enum
{
    swiftvlc_subtitle_text_placement_automatic = 0,
    swiftvlc_subtitle_text_placement_webvtt = 1,
};

typedef uint32_t swiftvlc_webvtt_horizontal_anchor_t;
enum
{
    swiftvlc_webvtt_horizontal_anchor_center = 0,
    swiftvlc_webvtt_horizontal_anchor_left = 1,
    swiftvlc_webvtt_horizontal_anchor_right = 2,
};

typedef uint32_t swiftvlc_webvtt_vertical_anchor_t;
enum
{
    swiftvlc_webvtt_vertical_anchor_center = 0,
    swiftvlc_webvtt_vertical_anchor_top = 1,
    swiftvlc_webvtt_vertical_anchor_bottom = 2,
};

typedef uint32_t swiftvlc_webvtt_text_alignment_t;
enum
{
    swiftvlc_webvtt_text_alignment_center = 0,
    swiftvlc_webvtt_text_alignment_left = 1,
    swiftvlc_webvtt_text_alignment_right = 2,
};

typedef uint32_t swiftvlc_webvtt_writing_direction_t;
enum
{
    swiftvlc_webvtt_writing_direction_horizontal = 0,
    swiftvlc_webvtt_writing_direction_vertical_growing_left = 1,
    swiftvlc_webvtt_writing_direction_vertical_growing_right = 2,
};

enum
{
    SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_WIDTH = 1u << 0,
    SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_HEIGHT = 1u << 1,
};

/**
 * Parsed WebVTT placement in normalized video coordinates.
 *
 * Horizontal and vertical positions identify a point in the video viewport;
 * the corresponding anchor identifies which point of the rendered cue box is
 * placed there. Maximum extents are meaningful only when the corresponding
 * SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_* flag is set. Renderer safety
 * margins and collision avoidance are intentionally not folded into these
 * semantic cue values.
 */
typedef struct swiftvlc_webvtt_placement_t
{
    float horizontal_position;
    float vertical_position;
    float maximum_width;
    float maximum_height;
    uint32_t flags;
    swiftvlc_webvtt_horizontal_anchor_t horizontal_anchor;
    swiftvlc_webvtt_vertical_anchor_t vertical_anchor;
    swiftvlc_webvtt_text_alignment_t text_alignment;
    swiftvlc_webvtt_writing_direction_t writing_direction;
} swiftvlc_webvtt_placement_t;

/** One ordered semantic text region in a version-10 snapshot. */
typedef struct swiftvlc_subtitle_text_region_t
{
    const char *text;
    swiftvlc_subtitle_text_placement_kind_t placement;
    swiftvlc_webvtt_placement_t webvtt;
} swiftvlc_subtitle_text_region_t;

/** Ordered semantic text-region snapshot callback. */
typedef void (*swiftvlc_subtitle_text_snapshot_cb)(
    void *opaque,
    const swiftvlc_subtitle_text_region_t *regions,
    size_t region_count );

#if defined(__cplusplus)
# define SWIFTVLC_SUBTITLE_STATIC_ASSERT(condition, message) \
    static_assert(condition, message)
#else
# define SWIFTVLC_SUBTITLE_STATIC_ASSERT(condition, message) \
    _Static_assert(condition, message)
#endif

SWIFTVLC_SUBTITLE_STATIC_ASSERT(
    offsetof(swiftvlc_webvtt_placement_t, horizontal_position) == 0,
    "SwiftVLC WebVTT placement position offset changed");
SWIFTVLC_SUBTITLE_STATIC_ASSERT(
    offsetof(swiftvlc_webvtt_placement_t, flags) == 16,
    "SwiftVLC WebVTT placement flags offset changed");
SWIFTVLC_SUBTITLE_STATIC_ASSERT(
    offsetof(swiftvlc_webvtt_placement_t, writing_direction) == 32,
    "SwiftVLC WebVTT placement direction offset changed");
SWIFTVLC_SUBTITLE_STATIC_ASSERT(sizeof(swiftvlc_webvtt_placement_t) == 36,
    "SwiftVLC WebVTT placement ABI size changed");
SWIFTVLC_SUBTITLE_STATIC_ASSERT(
    offsetof(swiftvlc_subtitle_text_region_t, placement) == sizeof(const char *),
    "SwiftVLC subtitle region placement offset changed");
SWIFTVLC_SUBTITLE_STATIC_ASSERT(
    offsetof(swiftvlc_subtitle_text_region_t, webvtt)
        == sizeof(const char *) + sizeof(uint32_t),
    "SwiftVLC subtitle region WebVTT offset changed");
SWIFTVLC_SUBTITLE_STATIC_ASSERT(
    sizeof(swiftvlc_subtitle_text_region_t)
        == sizeof(const char *) + sizeof(uint32_t)
         + sizeof(swiftvlc_webvtt_placement_t),
    "SwiftVLC subtitle region ABI size changed");

#undef SWIFTVLC_SUBTITLE_STATIC_ASSERT

#endif /* VLC_SWIFTVLC_SUBTITLE_H */
