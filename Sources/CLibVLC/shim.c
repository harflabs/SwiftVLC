// CLibVLC shim — helpers for Swift interop with libVLC C API.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CLibVLC.h"

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
/// Returns a context pointer that must be freed with swiftvlc_log_unset().
void *swiftvlc_log_set(libvlc_instance_t *instance,
                        swiftvlc_log_cb callback,
                        void *data) {
    struct swiftvlc_log_context *context = malloc(sizeof(*context));
    context->callback = callback;
    context->data = data;
    libvlc_log_set(instance, swiftvlc_log_bridge, context);
    return context;
}

/// Unsets the log callback and frees the bridge context.
void swiftvlc_log_unset(libvlc_instance_t *instance, void *context) {
    libvlc_log_unset(instance);
    free(context);
}
