// CLibVLC shim — helpers for Swift interop with libVLC C API.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CLibVLC.h"

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
void swiftvlc_libvlc_video_set_format_callbacks_ex(
    libvlc_media_player_t *player,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup) {
    (void)player;
    (void)setup;
    (void)cleanup;
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
