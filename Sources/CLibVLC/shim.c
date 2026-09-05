// CLibVLC shim — helpers for Swift interop with libVLC C API.

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CLibVLC.h"

_Static_assert(sizeof(((libvlc_event_t *)0)->u) == 24,
               "vendored libvlc event union ABI changed");
_Static_assert(sizeof(libvlc_event_t) == 40,
               "vendored libvlc event ABI changed");
_Static_assert(offsetof(libvlc_event_t, u) == 16,
               "vendored libvlc event union offset changed");
_Static_assert(
    sizeof(((libvlc_event_t *)0)->u.media_player_frame_step_completed) == 24,
    "vendored strict frame-step payload ABI changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.request_id) == 16,
    "vendored strict request-id offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.time_us) == 24,
    "vendored strict time offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.status) == 32,
    "vendored strict status offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.position) == 36,
    "vendored strict position offset changed");
_Static_assert(
    sizeof(((libvlc_event_t *)0)->u.media_player_rate_changed) == 4,
    "vendored effective rate payload ABI changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_rate_changed.new_rate) == 16,
    "vendored effective rate offset changed");
_Static_assert(sizeof(swiftvlc_sample_buffer_renderer_snapshot_t) == 136,
    "vendored native renderer snapshot size changed");
_Static_assert(_Alignof(swiftvlc_sample_buffer_renderer_snapshot_t) == 8,
    "vendored native renderer snapshot alignment changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    abi_version) == 0, "native renderer ABI-version offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    flags) == 4, "native renderer flags offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    display_generation) == 8, "native renderer generation offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    recovery_episode_count) == 16, "native renderer episode offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    recovered_episode_count) == 24, "native renderer recovered offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    requirement_notification_count) == 32,
    "native renderer requirement offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    revocation_notification_count) == 40,
    "native renderer revocation offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    decode_failure_notification_count) == 48,
    "native renderer decode-failure offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    foreground_check_count) == 56,
    "native renderer foreground-check offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    recovery_flush_count) == 64, "native renderer recovery-flush offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    revocation_flush_count) == 72,
    "native renderer revocation-flush offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    failure_flush_count) == 80, "native renderer failure-flush offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    discontinuity_flush_count) == 88,
    "native renderer discontinuity-flush offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    successful_submission_count) == 96,
    "native renderer successful-submission offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    recovery_submission_count) == 104,
    "native renderer recovery-submission offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    retryable_submission_count) == 112,
    "native renderer retryable-submission offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    recovery_sample_failure_count) == 120,
    "native renderer recovery-sample-failure offset changed");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
    permanent_failure_count) == 128,
    "native renderer permanent-failure offset changed");
_Static_assert(sizeof(swiftvlc_apple_audio_recovery_snapshot_t) == 120,
    "vendored Apple audio recovery snapshot size changed");
_Static_assert(_Alignof(swiftvlc_apple_audio_recovery_snapshot_t) == 8,
    "vendored Apple audio recovery snapshot alignment changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    broker_epoch) == 16, "Apple audio broker epoch offset changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    command_generation) == 32, "Apple audio command offset changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    command_dispatched) == 88, "Apple audio dispatch offset changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    broker_active_owner_count) == 96,
    "Apple audio owner-count offset changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    broker_live_lease_count) == 100,
    "Apple audio lease-count offset changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    broker_successful_deactivation_count) == 104,
    "Apple audio deactivation-success offset changed");
_Static_assert(offsetof(swiftvlc_apple_audio_recovery_snapshot_t,
    broker_failed_deactivation_count) == 112,
    "Apple audio deactivation-failure offset changed");
_Static_assert(sizeof(swiftvlc_pip_playback_identity_t) == 16,
    "vendored native PiP playback identity size changed");
_Static_assert(_Alignof(swiftvlc_pip_playback_identity_t) == 8,
    "vendored native PiP playback identity alignment changed");

#if defined(__APPLE__)
/*
 * The released static archive predates these symbols. Weak definitions keep
 * that archive linkable; a patched archive's strong definitions win because
 * the same media_player.o is already selected by SwiftVLC's standard player
 * API references. The version function makes fallback vs. strong selection
 * observable without relying on weak-import behavior (which still requires a
 * provider dylib at static-link time on Darwin).
 */
__attribute__((weak))
unsigned swiftvlc_libvlc_pip_extensions_version(void) {
    return 0;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_set_pip_playback_identity(
    libvlc_media_player_t *player,
    uint64_t native_handle_identity,
    uint64_t playback_generation) {
    (void)player;
    (void)native_handle_identity;
    (void)playback_generation;
    return false;
}

__attribute__((weak))
void swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(
    libvlc_media_player_t *player, int paused) {
    libvlc_media_player_set_pause(player, paused);
}

__attribute__((weak))
int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(
    libvlc_media_player_t *player,
    swiftvlc_apple_audio_session_lease_t *lease) {
    (void)player;
    if (lease != NULL) {
        *lease = 0;
    }
    return swiftvlc_apple_audio_session_lease_failed;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(
    libvlc_media_player_t *player,
    swiftvlc_apple_audio_session_lease_t lease) {
    (void)player;
    (void)lease;
    return false;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(
    libvlc_media_player_t *player,
    swiftvlc_apple_audio_recovery_snapshot_t *snapshot) {
    if (player == NULL || snapshot == NULL
        || snapshot->version != SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION
        || snapshot->size != sizeof(*snapshot)) {
        return false;
    }
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->version = SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION;
    snapshot->size = sizeof(*snapshot);
    snapshot->broker_phase = swiftvlc_apple_audio_media_services_ready;
    snapshot->command_origin = swiftvlc_apple_audio_command_invalidating;
    return false;
}

__attribute__((weak))
void swiftvlc_libvlc_video_set_format_callbacks_ex(
    libvlc_media_player_t *player,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup) {
    (void)player;
    (void)setup;
    (void)cleanup;
}

__attribute__((weak))
void swiftvlc_libvlc_video_set_display_status_callback(
    libvlc_media_player_t *player,
    swiftvlc_video_display_status_cb display) {
    (void)player;
    (void)display;
}

__attribute__((weak))
int swiftvlc_libvlc_video_set_callbacks_atomic(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_cb display_status,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque) {
    (void)player;
    (void)lock;
    (void)unlock;
    (void)display;
    (void)display_status;
    (void)setup;
    (void)cleanup;
    (void)opaque;
    return -ENOSYS;
}

__attribute__((weak))
int swiftvlc_libvlc_video_set_callbacks_atomic_v2(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_v2_cb display_status_v2,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque) {
    (void)player;
    (void)lock;
    (void)unlock;
    (void)display;
    (void)display_status_v2;
    (void)setup;
    (void)cleanup;
    (void)opaque;
    return -ENOSYS;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_get_media_length_snapshot(
    libvlc_media_player_t *player,
    swiftvlc_media_player_media_length_snapshot_t *snapshot) {
    (void)player;
    if (snapshot != NULL) {
        snapshot->media = NULL;
        snapshot->length = -1;
    }
    return false;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_get_playback_snapshot(
    libvlc_media_player_t *player,
    swiftvlc_media_player_playback_snapshot_t *snapshot) {
    (void)player;
    if (snapshot != NULL) {
        snapshot->media = NULL;
        snapshot->length = -1;
        snapshot->time = -1;
        snapshot->seekable = false;
    }
    return false;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback(
    libvlc_media_player_t *player,
    swiftvlc_subtitle_text_snapshot_cb callback,
    void *opaque) {
    (void)player;
    (void)callback;
    (void)opaque;
    return false;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot(
    libvlc_media_player_t *player,
    swiftvlc_sample_buffer_renderer_snapshot_t *snapshot) {
    (void)player;
    if (snapshot != NULL) {
        memset(snapshot, 0, sizeof(*snapshot));
        snapshot->abi_version = 1;
    }
    return false;
}

__attribute__((weak))
swiftvlc_next_frame_request_result_t
swiftvlc_libvlc_media_player_request_next_frame(
    libvlc_media_player_t *player,
    uint64_t request_id) {
    (void)player;
    (void)request_id;
    return swiftvlc_next_frame_request_unavailable;
}

__attribute__((weak))
bool swiftvlc_libvlc_media_player_cancel_next_frame_request(
    libvlc_media_player_t *player,
    uint64_t request_id) {
    (void)player;
    (void)request_id;
    return false;
}

#endif

/// Wrapper for libvlc_log_set that formats the va_list message in C
/// and calls a simpler Swift-compatible callback with the formatted string.
///
/// Swift can't easily handle C va_list arguments, so we format here
/// and pass the result to a simplified callback.
typedef void (*swiftvlc_log_cb)(void *data, int level,
                                 const char *module,
                                 const char *message);

struct swiftvlc_log_context {
    swiftvlc_log_cb callback;
    void *data;
};

static void swiftvlc_log_bridge(void *data, int level,
                                 const libvlc_log_t *ctx,
                                 const char *fmt, va_list args) {
    struct swiftvlc_log_context *context = (struct swiftvlc_log_context *)data;

    // Format the message
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, args);

    // Get module name
    const char *module = NULL;
    const char *header = NULL;
    unsigned line = 0;
    libvlc_log_get_context(ctx, &module, &header, &line);

    context->callback(context->data, level, module, buf);
}

/// Sets up a simplified log callback that receives pre-formatted messages.
/// Returns a context pointer that must be freed with swiftvlc_log_unset(),
/// or NULL on allocation failure.
void *swiftvlc_log_set(libvlc_instance_t *instance,
                        swiftvlc_log_cb callback,
                        void *data) {
    struct swiftvlc_log_context *context = malloc(sizeof(*context));
    if (!context) {
        return NULL;
    }
    context->callback = callback;
    context->data = data;
    libvlc_log_set(instance, swiftvlc_log_bridge, context);
    return context;
}

/// Unsets the log callback and frees the bridge context.
/// Safe to call with a NULL context — only clears the libVLC log callback.
void swiftvlc_log_unset(libvlc_instance_t *instance, void *context) {
    libvlc_log_unset(instance);
    free(context);
}

bool swiftvlc_video_set_format_callbacks_ex_if_available(
    libvlc_media_player_t *player,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 1) {
        return false;
    }
    swiftvlc_libvlc_video_set_format_callbacks_ex(player, setup, cleanup);
    return true;
#else
    (void)player;
    (void)setup;
    (void)cleanup;
    return false;
#endif
}

bool swiftvlc_video_format_callbacks_ex_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 1;
#else
    return false;
#endif
}

int swiftvlc_video_set_callbacks_atomic_if_available(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_cb display_status,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 4) {
        return -ENOSYS;
    }
    return swiftvlc_libvlc_video_set_callbacks_atomic(
        player, lock, unlock, display, display_status, setup, cleanup, opaque);
#else
    (void)player;
    (void)lock;
    (void)unlock;
    (void)display;
    (void)display_status;
    (void)setup;
    (void)cleanup;
    (void)opaque;
    return -ENOSYS;
#endif
}

bool swiftvlc_video_callbacks_atomic_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 4;
#else
    return false;
#endif
}

int swiftvlc_video_set_callbacks_atomic_v2_if_available(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_v2_cb display_status_v2,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 6) {
        return -ENOSYS;
    }
    return swiftvlc_libvlc_video_set_callbacks_atomic_v2(
        player, lock, unlock, display, display_status_v2, setup, cleanup,
        opaque);
#else
    (void)player;
    (void)lock;
    (void)unlock;
    (void)display;
    (void)display_status_v2;
    (void)setup;
    (void)cleanup;
    (void)opaque;
    return -ENOSYS;
#endif
}

bool swiftvlc_video_callbacks_atomic_v2_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 6;
#else
    return false;
#endif
}

bool swiftvlc_video_set_display_status_callback_if_available(
    libvlc_media_player_t *player,
    swiftvlc_video_display_status_cb display) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 4) {
        return false;
    }
    swiftvlc_libvlc_video_set_display_status_callback(player, display);
    return true;
#else
    (void)player;
    (void)display;
    return false;
#endif
}

bool swiftvlc_media_player_get_media_length_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_media_player_media_length_snapshot_t *snapshot) {
    if (snapshot == NULL) {
        return false;
    }
    snapshot->media = NULL;
    snapshot->length = -1;
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 1) {
        return false;
    }
    return swiftvlc_libvlc_media_player_get_media_length_snapshot(
        player, snapshot);
#else
    (void)player;
    return false;
#endif
}

bool swiftvlc_media_length_snapshot_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 1;
#else
    return false;
#endif
}

bool swiftvlc_media_player_get_playback_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_media_player_playback_snapshot_t *snapshot) {
    if (snapshot == NULL) {
        return false;
    }
    snapshot->media = NULL;
    snapshot->length = -1;
    snapshot->time = -1;
    snapshot->seekable = false;
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 2) {
        return false;
    }
    return swiftvlc_libvlc_media_player_get_playback_snapshot(
        player, snapshot);
#else
    (void)player;
    return false;
#endif
}

bool swiftvlc_playback_snapshot_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 2;
#else
    return false;
#endif
}

bool swiftvlc_media_player_get_sample_buffer_renderer_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_sample_buffer_renderer_snapshot_t *snapshot) {
    if (snapshot == NULL) {
        return false;
    }
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->abi_version = 1;
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 5) {
        return false;
    }
    return swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot(
        player, snapshot);
#else
    (void)player;
    return false;
#endif
}

bool swiftvlc_sample_buffer_renderer_snapshot_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 5;
#else
    return false;
#endif
}

bool swiftvlc_native_pip_overlay_composition_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 3;
#else
    return false;
#endif
}

bool swiftvlc_media_player_set_subtitle_text_snapshot_callback_if_available(
    libvlc_media_player_t *player,
    swiftvlc_subtitle_text_snapshot_cb callback,
    void *opaque) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 10) {
        return false;
    }
    return swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback(
        player, callback, opaque);
#else
    (void)player;
    (void)callback;
    (void)opaque;
    return false;
#endif
}

bool swiftvlc_subtitle_text_snapshot_callback_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 10;
#else
    return false;
#endif
}

swiftvlc_next_frame_request_result_t
swiftvlc_media_player_request_next_frame_if_available(
    libvlc_media_player_t *player,
    uint64_t request_id) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 4) {
        return swiftvlc_next_frame_request_unavailable;
    }
    return swiftvlc_libvlc_media_player_request_next_frame(player, request_id);
#else
    (void)player;
    (void)request_id;
    return swiftvlc_next_frame_request_unavailable;
#endif
}

bool swiftvlc_media_player_cancel_next_frame_request_if_available(
    libvlc_media_player_t *player,
    uint64_t request_id) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 4) {
        return false;
    }
    return swiftvlc_libvlc_media_player_cancel_next_frame_request(
        player, request_id);
#else
    (void)player;
    (void)request_id;
    return false;
#endif
}

bool swiftvlc_strict_frame_step_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 4;
#else
    return false;
#endif
}

bool swiftvlc_media_player_rate_changed_event_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 7;
#else
    return false;
#endif
}

bool swiftvlc_media_player_set_pip_playback_identity_if_available(
    libvlc_media_player_t *player,
    uint64_t native_handle_identity,
    uint64_t playback_generation) {
#if defined(__APPLE__)
    if (swiftvlc_libvlc_pip_extensions_version() < 9) {
        return false;
    }
    return swiftvlc_libvlc_media_player_set_pip_playback_identity(
        player, native_handle_identity, playback_generation);
#else
    (void)player;
    (void)native_handle_identity;
    (void)playback_generation;
    return false;
#endif
}

bool swiftvlc_native_pip_handoff_v9_available(void) {
#if defined(__APPLE__)
    return swiftvlc_libvlc_pip_extensions_version() >= 9;
#else
    return false;
#endif
}
