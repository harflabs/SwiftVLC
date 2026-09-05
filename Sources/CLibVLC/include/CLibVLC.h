// CLibVLC.h — Umbrella header for the libVLC C API
// Exposes the raw libVLC 4.0 C functions to Swift via the CLibVLC module.

#ifndef CLibVLC_h
#define CLibVLC_h

#include "vlc/vlc.h"

// MARK: - Swift interop shims

/// Simplified log callback that receives pre-formatted messages.
/// Swift can't handle C va_list arguments, so the shim formats in C.
typedef void (*swiftvlc_log_cb)(void *data, int level,
                                 const char *module,
                                 const char *message);

/// Sets up a simplified log callback. Returns a context pointer
/// that must be freed with swiftvlc_log_unset().
void *swiftvlc_log_set(libvlc_instance_t *instance,
                        swiftvlc_log_cb callback,
                        void *data);

/// Unsets the log callback and frees the bridge context.
void swiftvlc_log_unset(libvlc_instance_t *instance, void *context);

/// Installs SwiftVLC's additive geometry-aware vmem callback when the linked
/// pinned libVLC exports it. Returns false without mutating callback state when
/// an older released libVLC binary is linked.
bool swiftvlc_video_set_format_callbacks_ex_if_available(
    libvlc_media_player_t *player,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup);

/// Returns whether the linked libVLC exports SwiftVLC's extended vmem ABI.
bool swiftvlc_video_format_callbacks_ex_available(void);

/// Publishes one complete strict-capable vmem callback generation when the
/// linked libVLC exposes extension version 4. Returns the native result and
/// returns -ENOSYS without mutating callback state on an older binary. A v4
/// validation or allocation failure is returned directly; callers must not
/// retry through the sequential legacy setters.
int swiftvlc_video_set_callbacks_atomic_if_available(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_cb display_status,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque);

/// Returns whether the linked libVLC declares atomic vmem generation support.
bool swiftvlc_video_callbacks_atomic_available(void);

/// Publishes one complete source-timestamp-bearing vmem callback generation
/// when the linked libVLC exposes extension version 6. Returns the native
/// result, or -ENOSYS without mutation on an older binary. Validation and
/// allocation failures are authoritative and must never fall through to the
/// v4 or sequential setters.
int swiftvlc_video_set_callbacks_atomic_v2_if_available(
    libvlc_media_player_t *player,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_v2_cb display_status_v2,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque);

/// Returns whether the linked libVLC declares the timestamp-bearing atomic-v2
/// vmem generation contract.
bool swiftvlc_video_callbacks_atomic_v2_available(void);

/// Installs the v4 result-bearing callback for subsequently opened vmem
/// outputs. Passing NULL restores legacy behavior for the next vmem output;
/// an already-open output retains its callback snapshot. The Bool reports ABI
/// availability only.
bool swiftvlc_video_set_display_status_callback_if_available(
    libvlc_media_player_t *player,
    swiftvlc_video_display_status_cb display);

/// Captures one retained-media/length snapshot when the linked pinned libVLC
/// exports the atomic extension. Returns false on older binaries or no media.
bool swiftvlc_media_player_get_media_length_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_media_player_media_length_snapshot_t *snapshot);

/// Returns whether the linked libVLC exports SwiftVLC's atomic snapshot ABI.
bool swiftvlc_media_length_snapshot_available(void);

/// Captures one retained-media/playback-state snapshot when the linked pinned
/// libVLC exports version 2 of the atomic extension. Returns false on older
/// binaries or when no media is loaded.
bool swiftvlc_media_player_get_playback_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_media_player_playback_snapshot_t *snapshot);

/// Returns whether the linked libVLC exports the complete playback snapshot.
bool swiftvlc_playback_snapshot_available(void);

/// Captures coherent native Apple sample-buffer renderer recovery evidence
/// when the linked pinned libVLC exports extension version 5. Successful
/// submissions count postflight-validated enqueue calls, not
/// AVFoundation-visible output.
bool swiftvlc_media_player_get_sample_buffer_renderer_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_sample_buffer_renderer_snapshot_t *snapshot);

/// Returns whether the linked libVLC exports native renderer recovery evidence.
bool swiftvlc_sample_buffer_renderer_snapshot_available(void);

/// Returns whether native sample-buffer PiP composites VLC subpictures.
bool swiftvlc_native_pip_overlay_composition_available(void);

/// Installs ordered semantic text-region snapshots when the linked pinned
/// libVLC exports extension version 10. Registration is allowed only before
/// the first successful playback start. Passing NULL clears a pre-play
/// registration.
bool swiftvlc_media_player_set_subtitle_text_snapshot_callback_if_available(
    libvlc_media_player_t *player,
    swiftvlc_subtitle_text_snapshot_cb callback,
    void *opaque);

/// Returns whether ordered semantic text-region snapshots are available.
bool swiftvlc_subtitle_text_snapshot_callback_available(void);

/// Submits one request-correlated frame step when the linked pinned libVLC
/// exports version 4 of the additive extension.
swiftvlc_next_frame_request_result_t
swiftvlc_media_player_request_next_frame_if_available(
    libvlc_media_player_t *player,
    uint64_t request_id);

/// Cancels a matching active strict frame step. A mismatch is idempotent.
bool swiftvlc_media_player_cancel_next_frame_request_if_available(
    libvlc_media_player_t *player,
    uint64_t request_id);

/// Returns whether request-correlated, post-display frame stepping is present.
bool swiftvlc_strict_frame_step_available(void);

/// Returns whether the linked pinned libVLC emits
/// libvlc_MediaPlayerRateChanged for effective control-rate resolutions.
bool swiftvlc_media_player_rate_changed_event_available(void);

/// Publishes the immutable native-handle/playback pair used by Apple PiP v9.
/// Returns false without mutation when an older archive is linked.
bool swiftvlc_media_player_set_pip_playback_identity_if_available(
    libvlc_media_player_t *player,
    uint64_t native_handle_identity,
    uint64_t playback_generation);

/// Returns whether exact handle/playback/output-correlated PiP handoff exists.
bool swiftvlc_native_pip_handoff_v9_available(void);

#endif /* CLibVLC_h */
