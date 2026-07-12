/*****************************************************************************
 * swiftvlc_vmem.h: SwiftVLC geometry-aware vmem callback ABI
 *****************************************************************************
 * This header intentionally depends only on fixed-width C types so the vmem
 * core module can consume the ABI without importing LibVLC's public API.
 *****************************************************************************/

#ifndef VLC_SWIFTVLC_VMEM_H
#define VLC_SWIFTVLC_VMEM_H 1

#include <stddef.h>
#include <stdint.h>

/**
 * One atomic post-rotation source-geometry snapshot supplied to
 * swiftvlc_video_format_ex_cb.
 *
 * The size, crop and sample-aspect fields describe a single post-rotation
 * video_format_ApplyRotation() snapshot, captured together so a callback sees
 * a consistent set of dimensions. source_orientation is the numeric value of
 * libvlc_video_orient_t before rotation was applied, recorded for diagnostics
 * only. It is fixed-width here so this ABI is independent of compiler enum
 * representation.
 */
typedef struct swiftvlc_video_format_geometry_t
{
    uint32_t coded_width;        /**< coded (buffer) width in pixels */
    uint32_t coded_height;       /**< coded (buffer) height in pixels */
    uint32_t visible_width;      /**< visible (cropped) width in pixels */
    uint32_t visible_height;     /**< visible (cropped) height in pixels */
    uint32_t x_offset;           /**< left crop offset into the coded buffer */
    uint32_t y_offset;           /**< top crop offset into the coded buffer */
    uint32_t sar_num;            /**< sample-aspect-ratio numerator */
    uint32_t sar_den;            /**< sample-aspect-ratio denominator */
    uint32_t source_orientation; /**< pre-rotation libvlc_video_orient_t value */
} swiftvlc_video_format_geometry_t;

/**
 * Geometry-aware custom-memory format callback.
 *
 * Unlike libvlc_video_format_cb, source_geometry preserves the exact coded,
 * visible, crop, sample-aspect and original-orientation state seen by the vmem
 * output. output_width and output_height select the delivered full-visible,
 * zero-offset surface. The extended vmem path accepts only an exact
 * square-pixel output aspect; an incompatible result fails setup.
 *
 * \param[in,out] opaque callback private pointer
 * \param[in,out] chroma four-byte video format identifier
 * \param[in] source_geometry atomic post-rotation source geometry
 * \param[in,out] output_width delivered full-visible width
 * \param[in,out] output_height delivered full-visible height
 * \param[out] pitches scanline pitches for every plane
 * \param[out] lines scanline counts for every plane
 * \return a positive setup success count, or zero on failure
 */
typedef unsigned (*swiftvlc_video_format_ex_cb)(
    void **opaque, char *chroma,
    const swiftvlc_video_format_geometry_t *source_geometry,
    unsigned *output_width, unsigned *output_height,
    unsigned *pitches, unsigned *lines);

#if defined(__cplusplus)
# define SWIFTVLC_VMEM_STATIC_ASSERT(condition, message) \
    static_assert(condition, message)
#else
# define SWIFTVLC_VMEM_STATIC_ASSERT(condition, message) \
    _Static_assert(condition, message)
#endif

SWIFTVLC_VMEM_STATIC_ASSERT(sizeof(swiftvlc_video_format_geometry_t) == 36,
    "SwiftVLC vmem geometry ABI size changed");
SWIFTVLC_VMEM_STATIC_ASSERT(
    offsetof(swiftvlc_video_format_geometry_t, coded_width) == 0,
    "SwiftVLC vmem coded_width offset changed");
SWIFTVLC_VMEM_STATIC_ASSERT(
    offsetof(swiftvlc_video_format_geometry_t, visible_width) == 8,
    "SwiftVLC vmem visible_width offset changed");
SWIFTVLC_VMEM_STATIC_ASSERT(
    offsetof(swiftvlc_video_format_geometry_t, x_offset) == 16,
    "SwiftVLC vmem x_offset offset changed");
SWIFTVLC_VMEM_STATIC_ASSERT(
    offsetof(swiftvlc_video_format_geometry_t, sar_num) == 24,
    "SwiftVLC vmem sar_num offset changed");
SWIFTVLC_VMEM_STATIC_ASSERT(
    offsetof(swiftvlc_video_format_geometry_t, source_orientation) == 32,
    "SwiftVLC vmem source_orientation offset changed");

#undef SWIFTVLC_VMEM_STATIC_ASSERT

#endif /* VLC_SWIFTVLC_VMEM_H */
