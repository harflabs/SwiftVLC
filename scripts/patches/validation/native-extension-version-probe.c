#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <vlc/vlc.h>

#ifndef SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION
# error "SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION is required"
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION < 1 \
 || SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION > 10
# error "unsupported SwiftVLC native extension version"
#endif

#ifndef SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES
# define SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES 0
#endif

#if SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES != 0 \
 && SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES != 1
# error "lease requirement must be zero or one"
#endif

#if SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES \
 && SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION < 8
# error "Apple audio-session leases require extension version 8"
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 9 \
 && !SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES
# error "extension versions 9 and newer inherit the Apple audio-session lease contract"
#endif

#define SWIFTVLC_ASSERT_FUNCTION_TYPE(function_name, pointer_type) \
    _Static_assert(_Generic(&(function_name), pointer_type: 1, default: 0), \
                   "unexpected signature for " #function_name)

typedef unsigned (*swiftvlc_version_function_t)(void);
typedef bool (*swiftvlc_media_length_snapshot_function_t)(
    libvlc_media_player_t *, swiftvlc_media_player_media_length_snapshot_t *);
typedef void (*swiftvlc_format_callbacks_ex_function_t)(
    libvlc_media_player_t *, swiftvlc_video_format_ex_cb,
    libvlc_video_cleanup_cb);

SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_pip_extensions_version,
    swiftvlc_version_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_get_media_length_snapshot,
    swiftvlc_media_length_snapshot_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_video_set_format_callbacks_ex,
    swiftvlc_format_callbacks_ex_function_t);

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 2
typedef bool (*swiftvlc_playback_snapshot_function_t)(
    libvlc_media_player_t *, swiftvlc_media_player_playback_snapshot_t *);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_get_playback_snapshot,
    swiftvlc_playback_snapshot_function_t);
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 4
typedef swiftvlc_next_frame_request_result_t
(*swiftvlc_request_next_frame_function_t)(libvlc_media_player_t *, uint64_t);
typedef bool (*swiftvlc_cancel_next_frame_function_t)(
    libvlc_media_player_t *, uint64_t);
typedef void (*swiftvlc_display_status_callback_function_t)(
    libvlc_media_player_t *, swiftvlc_video_display_status_cb);
typedef int (*swiftvlc_callbacks_atomic_function_t)(
    libvlc_media_player_t *, libvlc_video_lock_cb, libvlc_video_unlock_cb,
    libvlc_video_display_cb, swiftvlc_video_display_status_cb,
    swiftvlc_video_format_ex_cb, libvlc_video_cleanup_cb, void *);

SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_request_next_frame,
    swiftvlc_request_next_frame_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_cancel_next_frame_request,
    swiftvlc_cancel_next_frame_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_video_set_display_status_callback,
    swiftvlc_display_status_callback_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_video_set_callbacks_atomic,
    swiftvlc_callbacks_atomic_function_t);
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 5
typedef bool (*swiftvlc_renderer_snapshot_function_t)(
    libvlc_media_player_t *, swiftvlc_sample_buffer_renderer_snapshot_t *);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot,
    swiftvlc_renderer_snapshot_function_t);
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 6
typedef int (*swiftvlc_callbacks_atomic_v2_function_t)(
    libvlc_media_player_t *, libvlc_video_lock_cb, libvlc_video_unlock_cb,
    libvlc_video_display_cb, swiftvlc_video_display_status_v2_cb,
    swiftvlc_video_format_ex_cb, libvlc_video_cleanup_cb, void *);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_video_set_callbacks_atomic_v2,
    swiftvlc_callbacks_atomic_v2_function_t);
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 7
_Static_assert(libvlc_MediaPlayerRateChanged ==
                   libvlc_MediaPlayerFrameStepCompleted + 1,
               "effective-rate event is not append-only");
_Static_assert(
    sizeof(((libvlc_event_t *)0)->u.media_player_rate_changed.new_rate) ==
        sizeof(float),
    "unexpected effective-rate event payload");
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 8
# ifndef SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION
#  error "version 8 header is missing Apple audio recovery"
# endif
_Static_assert(SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION == 1,
               "unexpected Apple audio recovery snapshot version");
_Static_assert(sizeof(swiftvlc_apple_audio_recovery_snapshot_t) == 120,
               "unexpected Apple audio recovery snapshot size");

typedef bool (*swiftvlc_audio_recovery_snapshot_function_t)(
    libvlc_media_player_t *, swiftvlc_apple_audio_recovery_snapshot_t *);
typedef void (*swiftvlc_non_authorizing_pause_function_t)(
    libvlc_media_player_t *, int);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot,
    swiftvlc_audio_recovery_snapshot_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_set_pause_without_reset_authorization,
    swiftvlc_non_authorizing_pause_function_t);
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 9
_Static_assert(sizeof(swiftvlc_pip_playback_identity_t) == 16,
               "unexpected native PiP playback identity size");
_Static_assert(_Alignof(swiftvlc_pip_playback_identity_t) == 8,
               "unexpected native PiP playback identity alignment");
_Static_assert(offsetof(swiftvlc_pip_playback_identity_t,
                        native_handle_identity) == 0,
               "unexpected native-handle identity offset");
_Static_assert(offsetof(swiftvlc_pip_playback_identity_t,
                        playback_generation) == 8,
               "unexpected playback-generation offset");

typedef bool (*swiftvlc_set_pip_playback_identity_function_t)(
    libvlc_media_player_t *, uint64_t, uint64_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_set_pip_playback_identity,
    swiftvlc_set_pip_playback_identity_function_t);
#endif

#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 10
typedef bool (*swiftvlc_set_subtitle_text_snapshot_callback_function_t)(
    libvlc_media_player_t *, swiftvlc_subtitle_text_snapshot_cb, void *);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback,
    swiftvlc_set_subtitle_text_snapshot_callback_function_t);
#endif

#if SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES
_Static_assert(sizeof(swiftvlc_apple_audio_session_lease_t) == sizeof(uint64_t),
               "unexpected Apple audio-session lease width");
_Static_assert(swiftvlc_apple_audio_session_lease_failed == -1,
               "unexpected failed lease result");
_Static_assert(swiftvlc_apple_audio_session_lease_application_managed == 0,
               "unexpected application-managed lease result");
_Static_assert(swiftvlc_apple_audio_session_lease_acquired == 1,
               "unexpected acquired lease result");
typedef int (*swiftvlc_acquire_audio_session_lease_function_t)(
    libvlc_media_player_t *, swiftvlc_apple_audio_session_lease_t *);
typedef bool (*swiftvlc_release_audio_session_lease_function_t)(
    libvlc_media_player_t *, swiftvlc_apple_audio_session_lease_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease,
    swiftvlc_acquire_audio_session_lease_function_t);
SWIFTVLC_ASSERT_FUNCTION_TYPE(
    swiftvlc_libvlc_media_player_release_apple_audio_session_lease,
    swiftvlc_release_audio_session_lease_function_t);
#endif

int main(void)
{
    const unsigned actual = swiftvlc_libvlc_pip_extensions_version();
    const unsigned expected = SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION;
    if (actual != expected)
    {
        fprintf(stderr,
                "native extension version mismatch: expected %u, actual %u\n",
                expected, actual);
        return 1;
    }
#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 9
    if (swiftvlc_libvlc_media_player_set_pip_playback_identity(
            NULL, UINT64_C(1), UINT64_C(1)))
    {
        fputs("native PiP identity setter accepted a null player\n", stderr);
        return 1;
    }
#endif
#if SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION >= 10
    if (swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback(
            NULL, NULL, NULL))
    {
        fputs("subtitle text callback setter accepted a null player\n", stderr);
        return 1;
    }
#endif
    printf("%u\n", actual);
    return 0;
}
