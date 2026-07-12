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

/// Captures one retained-media/length snapshot when the linked pinned libVLC
/// exports the atomic extension. Returns false on older binaries or no media.
bool swiftvlc_media_player_get_media_length_snapshot_if_available(
    libvlc_media_player_t *player,
    swiftvlc_media_player_media_length_snapshot_t *snapshot);

/// Returns whether the linked libVLC exports SwiftVLC's atomic snapshot ABI.
bool swiftvlc_media_length_snapshot_available(void);

#endif /* CLibVLC_h */
