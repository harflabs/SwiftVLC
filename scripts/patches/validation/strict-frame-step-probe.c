/* Runtime and ABI proof for SwiftVLC's version-4 strict frame-step contract. */
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vlc/vlc.h>

#ifndef SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION
# define SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION 4
#endif

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
# include <vlc_common.h>
# ifndef N_
#  define N_(string) string
# endif
# include "lib/libvlc_internal.h"
# include "lib/media_player_internal.h"
# include "src/player/player.h"
# include "src/input/input_internal.h"
# include "src/input/es_out.h"
# include "src/video_output/vout_internal.h"
#endif

_Static_assert(sizeof(((libvlc_event_t *)0)->u) == 24,
               "event union must remain compatible with released archives");
_Static_assert(sizeof(libvlc_event_t) == 40,
               "libvlc_event_t ABI size changed");
_Static_assert(
    sizeof(((libvlc_event_t *)0)->u.media_player_frame_step_completed) == 24,
    "strict frame-step payload exceeds the released event union");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.request_id) == 16,
    "strict request-id event offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.time_us) == 24,
    "strict time event offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.status) == 32,
    "strict status event offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.position) == 36,
    "strict position event offset changed");
_Static_assert(swiftvlc_frame_step_status_success == 0
            && swiftvlc_frame_step_status_paused_for_retry == 1
            && swiftvlc_frame_step_status_no_frame == 2,
               "strict terminal status ABI changed");

struct vmem_context
{
    void *pixels;
    size_t size;
    atomic_uint lock_count;
    atomic_uint display_count;
    atomic_uint status_count;
    atomic_uint setup_count;
    atomic_uint cleanup_count;
    int submission_status;
    pthread_mutex_t submission_barrier_lock;
    pthread_cond_t submission_barrier_changed;
    atomic_bool submission_barrier_enabled;
    atomic_bool submission_barrier_waiting;
};

static void *vmem_lock(void *opaque, void **planes)
{
    struct vmem_context *context = opaque;
    planes[0] = context->pixels;
    atomic_fetch_add_explicit(&context->lock_count, 1, memory_order_relaxed);
    return context;
}

static void vmem_display(void *opaque, void *picture)
{
    struct vmem_context *context = opaque;
    if (picture == context)
        atomic_fetch_add_explicit(&context->display_count, 1,
                                  memory_order_relaxed);
}

static int vmem_display_submission(void *opaque, void *picture)
{
    struct vmem_context *context = opaque;
    if (picture != context)
        return -EINVAL;
    atomic_fetch_add_explicit(&context->status_count, 1,
                              memory_order_relaxed);
    if (atomic_load_explicit(&context->submission_barrier_enabled,
                             memory_order_acquire))
    {
        pthread_mutex_lock(&context->submission_barrier_lock);
        atomic_store_explicit(&context->submission_barrier_waiting, true,
                              memory_order_release);
        pthread_cond_broadcast(&context->submission_barrier_changed);
        while (atomic_load_explicit(&context->submission_barrier_enabled,
                                    memory_order_acquire))
            pthread_cond_wait(&context->submission_barrier_changed,
                              &context->submission_barrier_lock);
        atomic_store_explicit(&context->submission_barrier_waiting, false,
                              memory_order_release);
        pthread_mutex_unlock(&context->submission_barrier_lock);
    }
    return context->submission_status;
}

static unsigned vmem_setup(void **opaque, char *chroma, unsigned *width,
                           unsigned *height, unsigned *pitches,
                           unsigned *lines)
{
    struct vmem_context *context = *opaque;
    memcpy(chroma, "RV32", 4);
    pitches[0] = ((*width * 4u) + 31u) & ~31u;
    lines[0] = (*height + 31u) & ~31u;
    size_t size = (size_t)pitches[0] * lines[0];
    void *pixels = NULL;
    if (posix_memalign(&pixels, 32, size) != 0)
        return 0;
    free(context->pixels);
    context->pixels = pixels;
    context->size = size;
    memset(context->pixels, 0, context->size);
    atomic_fetch_add_explicit(&context->setup_count, 1,
                              memory_order_relaxed);
    return 1;
}

static unsigned vmem_setup_ex(
    void **opaque, char *chroma,
    const swiftvlc_video_format_geometry_t *geometry,
    unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines)
{
    if (geometry == NULL || geometry->visible_width == 0
     || geometry->visible_height == 0)
        return 0;
    *width = geometry->visible_width;
    *height = geometry->visible_height;
    return vmem_setup(opaque, chroma, width, height, pitches, lines);
}

static void vmem_cleanup(void *opaque)
{
    struct vmem_context *context = opaque;
    free(context->pixels);
    context->pixels = NULL;
    context->size = 0;
    atomic_fetch_add_explicit(&context->cleanup_count, 1,
                              memory_order_relaxed);
}

struct completion
{
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned count;
    uint64_t request_id;
    int status;
    int64_t time_us;
    double position;
    struct {
        uint64_t request_id;
        int status;
        int64_t time_us;
        double position;
    } history[512];
    libvlc_media_player_t *reentrant_player;
    uint64_t reentrant_trigger_id;
    uint64_t reentrant_request_id;
    bool reentrant_armed;
    bool reentrant_called;
    swiftvlc_next_frame_request_result_t reentrant_result;
    libvlc_media_player_t *nested_pause_player;
    uint64_t nested_pause_trigger_id;
    bool nested_pause_armed;
    bool nested_pause_called;
};

static void deadline_after(struct timespec *deadline, long milliseconds);
static void sleep_milliseconds(long milliseconds);

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
enum core_step_kind { core_step_legacy, core_step_strict };

struct core_step_event
{
    enum core_step_kind kind;
    uint64_t request_id;
    int status;
};

struct core_step_order
{
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned count;
    struct core_step_event history[2048];
};

static void core_on_legacy(vlc_player_t *player, int status, void *opaque)
{
    (void) player;
    struct core_step_order *order = opaque;
    pthread_mutex_lock(&order->lock);
    unsigned index = order->count++;
    if (index < sizeof(order->history) / sizeof(order->history[0]))
        order->history[index] = (struct core_step_event) {
            .kind = core_step_legacy, .status = status,
        };
    pthread_cond_broadcast(&order->changed);
    pthread_mutex_unlock(&order->lock);
}

static void core_on_strict(vlc_player_t *player, uint64_t request_id,
                           int status, vlc_tick_t time, double position,
                           void *opaque)
{
    (void) player;
    (void) time;
    (void) position;
    struct core_step_order *order = opaque;
    pthread_mutex_lock(&order->lock);
    unsigned index = order->count++;
    if (index < sizeof(order->history) / sizeof(order->history[0]))
        order->history[index] = (struct core_step_event) {
            .kind = core_step_strict,
            .request_id = request_id,
            .status = status,
        };
    pthread_cond_broadcast(&order->changed);
    pthread_mutex_unlock(&order->lock);
}

static const struct vlc_player_cbs core_step_cbs = {
    .on_next_frame_status = core_on_legacy,
    .on_strict_next_frame_status = core_on_strict,
};

static vlc_player_listener_id *
attach_core_step_listener(libvlc_media_player_t *player,
                          struct core_step_order *order)
{
    vlc_player_Lock(player->player);
    vlc_player_listener_id *listener =
        vlc_player_AddListener(player->player, &core_step_cbs, order);
    vlc_player_Unlock(player->player);
    return listener;
}

static void detach_core_step_listener(libvlc_media_player_t *player,
                                      vlc_player_listener_id *listener)
{
    vlc_player_Lock(player->player);
    vlc_player_RemoveListener(player->player, listener);
    vlc_player_Unlock(player->player);
}

static bool force_terminal_allocation_failure(
    libvlc_media_player_t *player, bool enabled)
{
    vlc_player_Lock(player->player);
    struct vlc_player_input *input = player->player->input;
    bool available = input != NULL && input->started;
    if (available)
        input_ControlForceFrameNextTerminalAllocationFailure(input->thread,
                                                              enabled);
    vlc_player_Unlock(player->player);
    return available;
}

static bool force_commit_barrier(libvlc_media_player_t *player, bool enabled)
{
    vlc_player_Lock(player->player);
    struct vlc_player_input *input = player->player->input;
    bool available = input != NULL && input->started;
    if (available)
        input_ControlForceFrameNextCommitBarrier(input->thread, enabled);
    vlc_player_Unlock(player->player);
    return available;
}

static bool await_commit_barrier(libvlc_media_player_t *player,
                                 long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        vlc_player_Lock(player->player);
        struct vlc_player_input *input = player->player->input;
        bool waiting = input != NULL && input->started
                    && input_ControlFrameNextCommitWaiting(input->thread);
        vlc_player_Unlock(player->player);
        if (waiting)
            return true;
        sleep_milliseconds(10);
    }
    return false;
}

struct source_request_handle
{
    input_thread_t *input;
    uint64_t generation;
};

static struct source_request_handle
capture_source_request(libvlc_media_player_t *player)
{
    vlc_player_Lock(player->player);
    struct source_request_handle handle = {
        .input = player->player->input != NULL
               ? player->player->input->thread : NULL,
        .generation = player->player->strict_frame_request_generation,
    };
    vlc_player_Unlock(player->player);
    return handle;
}

static bool set_terminal_pop_barrier(struct source_request_handle handle,
                                     bool enabled)
{
    if (handle.input == NULL)
        return false;
    input_ControlForceFrameNextTerminalPopBarrier(handle.input, enabled);
    return true;
}

static bool await_terminal_pop_barrier(struct source_request_handle handle,
                                       long timeout_ms)
{
    if (handle.input == NULL)
        return false;
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        if (input_ControlFrameNextTerminalPopWaiting(handle.input))
            return true;
        sleep_milliseconds(10);
    }
    return false;
}

static bool await_natural_eof_quiescing(struct source_request_handle handle,
                                        long timeout_ms)
{
    if (handle.input == NULL)
        return false;
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        if (input_ControlFrameNextNaturalEofQuiescing(handle.input))
            return true;
        sleep_milliseconds(10);
    }
    return false;
}

static bool await_terminal_in_transit(struct source_request_handle handle,
                                      uint64_t request_id, long timeout_ms)
{
    if (handle.input == NULL || handle.generation == 0)
        return false;
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        if (input_ControlFrameNextTerminalInTransit(
                handle.input, request_id, handle.generation))
            return true;
        sleep_milliseconds(10);
    }
    return false;
}

static uint64_t terminal_origin_count(struct source_request_handle handle)
{
    return handle.input == NULL ? UINT64_MAX
         : input_ControlFrameNextTerminalOriginCount(handle.input);
}

static bool withdraw_strict_set_for_deferred_probe(
    struct source_request_handle handle, uint64_t request_id)
{
    if (handle.input == NULL || handle.generation == 0)
        return false;
    input_thread_private_t *sys = input_priv(handle.input);
    vlc_mutex_lock(&sys->lock_control);
    const bool active = sys->strict_frame_active_request_id == request_id
                     && sys->strict_frame_active_generation
                            == handle.generation;
    if (active)
    {
        for (size_t index = 0; index < sys->strict_frame_control_count;
             ++index)
        {
            input_control_t *control = &sys->strict_frame_control[index];
            if (control->i_type == INPUT_CONTROL_SET_FRAME_NEXT
             && control->param.frame_next.request_id == request_id
             && control->param.frame_next.generation == handle.generation)
            {
                --sys->strict_frame_control_count;
                if (index < sys->strict_frame_control_count)
                    memmove(control, control + 1,
                            (sys->strict_frame_control_count - index)
                                * sizeof(*control));
                break;
            }
        }
    }
    vlc_mutex_unlock(&sys->lock_control);
    return active;
}

static uint64_t frame_next_submission_count(libvlc_media_player_t *player)
{
    vout_thread_t *vout = vlc_player_vout_Hold(player->player);
    if (vout == NULL)
        return UINT64_MAX;
    /* This internal hook is inert until the source-linked qualification
     * binary explicitly enables it. It is not exported by libvlc. */
    vout_EnableFrameNextSubmissionProbe(vout);
    uint64_t count = vout_GetFrameNextSubmissionCount(vout);
    vout_Release(vout);
    return count;
}

static bool frame_next_terminal_probe(libvlc_media_player_t *player,
                                      bool *in_flight,
                                      uint64_t *empty_attempts)
{
    vout_thread_t *vout = vlc_player_vout_Hold(player->player);
    if (vout == NULL)
        return false;
    *in_flight = vout_IsFrameNextTerminalInFlight(vout);
    *empty_attempts = vout_GetFrameNextEmptyWhileTerminalCount(vout);
    vout_Release(vout);
    return true;
}

static bool await_frame_next_empty_while_terminal_count(
    libvlc_media_player_t *player, uint64_t target, long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        bool in_flight;
        uint64_t count;
        if (!frame_next_terminal_probe(player, &in_flight, &count))
            return false;
        if (count >= target)
            return in_flight;
        sleep_milliseconds(10);
    }
    return false;
}

static bool await_frame_next_submission_count(libvlc_media_player_t *player,
                                              uint64_t target,
                                              long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        uint64_t count = frame_next_submission_count(player);
        if (count == target)
            return true;
        if (count == UINT64_MAX || count > target)
            return false;
        sleep_milliseconds(10);
    }
    return false;
}

static bool await_terminal_origin_count(struct source_request_handle handle,
                                        uint64_t target, long timeout_ms)
{
    if (handle.input == NULL)
        return false;
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        uint64_t count = terminal_origin_count(handle);
        if (count == target)
            return true;
        if (count > target)
            return false;
        sleep_milliseconds(10);
    }
    return false;
}

static bool await_core_step_count(struct core_step_order *order,
                                  unsigned target, long timeout_ms)
{
    struct timespec deadline;
    deadline_after(&deadline, timeout_ms);
    pthread_mutex_lock(&order->lock);
    while (order->count < target)
        if (pthread_cond_timedwait(&order->changed, &order->lock,
                                   &deadline) == ETIMEDOUT)
            break;
    bool exact = order->count == target;
    pthread_mutex_unlock(&order->lock);
    return exact;
}

static bool check_core_mixed_order(struct core_step_order *order,
                                   unsigned baseline, uint64_t request_id,
                                   unsigned before, unsigned after,
                                   int legacy_status, int strict_status)
{
    const unsigned total = before + 1 + after;
    if (!await_core_step_count(order, baseline + total, 5000))
        return false;
    pthread_mutex_lock(&order->lock);
    bool valid = true;
    for (unsigned index = 0; valid && index < before; ++index)
        valid = order->history[baseline + index].kind == core_step_legacy
             && order->history[baseline + index].status == legacy_status;
    const struct core_step_event *strict =
        &order->history[baseline + before];
    valid = valid && strict->kind == core_step_strict
         && strict->request_id == request_id
         && strict->status == strict_status;
    for (unsigned index = 0; valid && index < after; ++index)
        valid = order->history[baseline + before + 1 + index].kind
                    == core_step_legacy
             && order->history[baseline + before + 1 + index].status
                    == legacy_status;
    pthread_mutex_unlock(&order->lock);
    return valid;
}

static bool check_core_legacy_order(struct core_step_order *order,
                                    unsigned baseline, unsigned count,
                                    int status)
{
    if (!await_core_step_count(order, baseline + count, 5000))
        return false;
    pthread_mutex_lock(&order->lock);
    bool valid = true;
    for (unsigned index = 0; valid && index < count; ++index)
        valid = order->history[baseline + index].kind == core_step_legacy
             && order->history[baseline + index].status == status;
    pthread_mutex_unlock(&order->lock);
    return valid;
}

static bool check_core_cancel_rebind_order(struct core_step_order *order,
                                           unsigned baseline,
                                           uint64_t canceled_id,
                                           uint64_t rebound_id)
{
    if (!await_core_step_count(order, baseline + 4, 5000))
        return false;
    pthread_mutex_lock(&order->lock);
    const struct core_step_event *events = &order->history[baseline];
    bool valid = events[0].kind == core_step_legacy
              && events[0].status == VLC_SUCCESS
              && events[1].kind == core_step_strict
              && events[1].request_id == canceled_id
              && events[1].status == -ECANCELED
              && events[2].kind == core_step_legacy
              && events[2].status == VLC_SUCCESS
              && events[3].kind == core_step_strict
              && events[3].request_id == rebound_id
              && events[3].status == VLC_SUCCESS;
    pthread_mutex_unlock(&order->lock);
    return valid;
}

static void dump_core_step_order(struct core_step_order *order,
                                 unsigned baseline)
{
    pthread_mutex_lock(&order->lock);
    fprintf(stderr, "core-order baseline=%u count=%u:", baseline,
            order->count);
    for (unsigned index = baseline; index < order->count; ++index)
        fprintf(stderr, " %c(%llu,%d)",
                order->history[index].kind == core_step_strict ? 'S' : 'L',
                (unsigned long long)order->history[index].request_id,
                order->history[index].status);
    fputc('\n', stderr);
    pthread_mutex_unlock(&order->lock);
}
#endif

static void on_completion(const libvlc_event_t *event, void *opaque)
{
    struct completion *completion = opaque;
    libvlc_media_player_t *reentrant_player = NULL;
    uint64_t reentrant_request_id = 0;
    libvlc_media_player_t *nested_pause_player = NULL;
    pthread_mutex_lock(&completion->lock);
    unsigned index = completion->count++;
    completion->request_id =
        event->u.media_player_frame_step_completed.request_id;
    completion->status = event->u.media_player_frame_step_completed.status;
    completion->time_us = event->u.media_player_frame_step_completed.time_us;
    completion->position =
        event->u.media_player_frame_step_completed.position;
    if (index < sizeof(completion->history) / sizeof(completion->history[0]))
    {
        completion->history[index].request_id = completion->request_id;
        completion->history[index].status = completion->status;
        completion->history[index].time_us = completion->time_us;
        completion->history[index].position = completion->position;
    }
    if (completion->reentrant_armed
     && completion->request_id == completion->reentrant_trigger_id)
    {
        completion->reentrant_armed = false;
        reentrant_player = completion->reentrant_player;
        reentrant_request_id = completion->reentrant_request_id;
    }
    if (completion->nested_pause_armed
     && completion->request_id == completion->nested_pause_trigger_id)
    {
        completion->nested_pause_armed = false;
        nested_pause_player = completion->nested_pause_player;
    }
    pthread_cond_broadcast(&completion->changed);
    pthread_mutex_unlock(&completion->lock);

    if (reentrant_player != NULL)
    {
        swiftvlc_next_frame_request_result_t result =
            swiftvlc_libvlc_media_player_request_next_frame(
                reentrant_player, reentrant_request_id);
        pthread_mutex_lock(&completion->lock);
        completion->reentrant_result = result;
        completion->reentrant_called = true;
        pthread_cond_broadcast(&completion->changed);
        pthread_mutex_unlock(&completion->lock);
    }
    if (nested_pause_player != NULL)
    {
        /* This nested reset must be sequenced after the outer resume whose
         * cancellation terminal triggered this callback. */
        libvlc_media_player_set_pause(nested_pause_player, 1);
        pthread_mutex_lock(&completion->lock);
        completion->nested_pause_called = true;
        pthread_cond_broadcast(&completion->changed);
        pthread_mutex_unlock(&completion->lock);
    }
}

static void deadline_after(struct timespec *deadline, long milliseconds)
{
    clock_gettime(CLOCK_REALTIME, deadline);
    deadline->tv_sec += milliseconds / 1000;
    deadline->tv_nsec += (milliseconds % 1000) * 1000000;
    if (deadline->tv_nsec >= 1000000000)
    {
        deadline->tv_sec++;
        deadline->tv_nsec -= 1000000000;
    }
}

static bool await_count(struct completion *completion, unsigned target,
                        long timeout_ms)
{
    struct timespec deadline;
    deadline_after(&deadline, timeout_ms);
    pthread_mutex_lock(&completion->lock);
    while (completion->count < target)
        if (pthread_cond_timedwait(&completion->changed, &completion->lock,
                                   &deadline) == ETIMEDOUT)
            break;
    bool reached = completion->count == target;
    pthread_mutex_unlock(&completion->lock);
    return reached;
}

static void sleep_milliseconds(long milliseconds)
{
    struct timespec delay = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000,
    };
    nanosleep(&delay, NULL);
}

static bool wait_for_state(libvlc_media_player_t *player,
                           libvlc_state_t state, long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        if (libvlc_media_player_get_state(player) == state)
            return true;
        sleep_milliseconds(10);
    }
    return false;
}

static bool wait_for_no_selected_video(libvlc_media_player_t *player,
                                       long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        libvlc_media_track_t *track =
            libvlc_media_player_get_selected_track(player,
                                                   libvlc_track_video);
        if (track == NULL)
            return true;
        libvlc_media_track_release(track);
        sleep_milliseconds(10);
    }
    return false;
}

static int check_terminal(struct completion *completion, unsigned target,
                          uint64_t request_id, int expected_status)
{
    if (!await_count(completion, target, 5000))
    {
        fprintf(stderr, "request %llu did not terminate\n",
                (unsigned long long)request_id);
        return 1;
    }

    pthread_mutex_lock(&completion->lock);
    const unsigned index = target - 1;
    bool valid = completion->history[index].request_id == request_id
              && completion->history[index].status == expected_status;
    if (expected_status == swiftvlc_frame_step_status_success)
        valid = valid && completion->history[index].time_us >= 0
              && (completion->history[index].position == -1.0
               || (completion->history[index].position >= 0.0
                && completion->history[index].position <= 1.0));
    pthread_mutex_unlock(&completion->lock);

    if (!valid)
    {
        fprintf(stderr, "invalid or duplicate terminal for request %llu\n",
                (unsigned long long)request_id);
        return 1;
    }
    return 0;
}

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
static int check_committed_terminal(struct completion *completion,
                                    unsigned target, uint64_t request_id)
{
    if (!await_count(completion, target, 5000))
        return 1;
    pthread_mutex_lock(&completion->lock);
    const unsigned index = target - 1;
    const bool valid = completion->history[index].request_id == request_id
        && completion->history[index].status
              == swiftvlc_frame_step_status_success;
    pthread_mutex_unlock(&completion->lock);
    return valid ? 0 : 1;
}
#endif

static int check_cancel_pair(struct completion *completion, unsigned target,
                             uint64_t request_id)
{
    if (!await_count(completion, target, 5000))
        return 1;

    pthread_mutex_lock(&completion->lock);
    bool valid = target >= 2;
    for (unsigned index = target - 2; valid && index < target; ++index)
        valid = completion->history[index].request_id == request_id
             && completion->history[index].status == -ECANCELED;
    pthread_mutex_unlock(&completion->lock);
    return valid ? 0 : 1;
}

static void arm_reentrant_request(struct completion *completion,
                                  libvlc_media_player_t *player,
                                  uint64_t trigger_id, uint64_t request_id)
{
    pthread_mutex_lock(&completion->lock);
    completion->reentrant_player = player;
    completion->reentrant_trigger_id = trigger_id;
    completion->reentrant_request_id = request_id;
    completion->reentrant_armed = true;
    completion->reentrant_called = false;
    pthread_mutex_unlock(&completion->lock);
}

static bool await_reentrant_result(
    struct completion *completion,
    swiftvlc_next_frame_request_result_t expected)
{
    struct timespec deadline;
    deadline_after(&deadline, 5000);
    pthread_mutex_lock(&completion->lock);
    while (!completion->reentrant_called)
        if (pthread_cond_timedwait(&completion->changed, &completion->lock,
                                   &deadline) == ETIMEDOUT)
            break;
    bool valid = completion->reentrant_called
              && completion->reentrant_result == expected;
    pthread_mutex_unlock(&completion->lock);
    return valid;
}

static bool await_reentrant_busy(struct completion *completion)
{
    return await_reentrant_result(completion,
                                  swiftvlc_next_frame_request_busy);
}

static void arm_nested_pause(struct completion *completion,
                             libvlc_media_player_t *player,
                             uint64_t trigger_id)
{
    pthread_mutex_lock(&completion->lock);
    completion->nested_pause_player = player;
    completion->nested_pause_trigger_id = trigger_id;
    completion->nested_pause_armed = true;
    completion->nested_pause_called = false;
    pthread_mutex_unlock(&completion->lock);
}

static bool await_nested_pause(struct completion *completion)
{
    struct timespec deadline;
    deadline_after(&deadline, 5000);
    pthread_mutex_lock(&completion->lock);
    while (!completion->nested_pause_called)
        if (pthread_cond_timedwait(&completion->changed, &completion->lock,
                                   &deadline) == ETIMEDOUT)
            break;
    bool called = completion->nested_pause_called;
    pthread_mutex_unlock(&completion->lock);
    return called;
}

static swiftvlc_next_frame_request_result_t
request_after_reset_barrier(libvlc_media_player_t *player, uint64_t request_id)
{
    for (unsigned attempt = 0; attempt < 500; ++attempt)
    {
        swiftvlc_next_frame_request_result_t result =
            swiftvlc_libvlc_media_player_request_next_frame(player,
                                                             request_id);
        if (result != swiftvlc_next_frame_request_busy)
            return result;
        sleep_milliseconds(10);
    }
    return swiftvlc_next_frame_request_busy;
}

static bool await_atomic_at_least(atomic_uint *count, unsigned target,
                                  long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        if (atomic_load_explicit(count, memory_order_relaxed) >= target)
            return true;
        sleep_milliseconds(10);
    }
    return false;
}

static bool await_atomic_exact(atomic_uint *count, unsigned target,
                               long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        unsigned value = atomic_load_explicit(count, memory_order_relaxed);
        if (value == target)
            return true;
        if (value > target)
            return false;
        sleep_milliseconds(10);
    }
    return false;
}

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
static void set_submission_barrier(struct vmem_context *context, bool enabled)
{
    pthread_mutex_lock(&context->submission_barrier_lock);
    atomic_store_explicit(&context->submission_barrier_enabled, enabled,
                          memory_order_release);
    if (!enabled)
        pthread_cond_broadcast(&context->submission_barrier_changed);
    pthread_mutex_unlock(&context->submission_barrier_lock);
}

static bool await_submission_barrier(struct vmem_context *context,
                                     long timeout_ms)
{
    for (long elapsed = 0; elapsed < timeout_ms; elapsed += 10)
    {
        if (atomic_load_explicit(&context->submission_barrier_waiting,
                                 memory_order_acquire))
            return true;
        sleep_milliseconds(10);
    }
    return false;
}


#endif

static bool stop_at_quiescence(libvlc_media_player_t *player,
                               struct completion *completion,
                               unsigned exact_terminal_count)
{
    libvlc_media_player_stop_async(player);
    if (!wait_for_state(player, libvlc_Stopped, 5000))
        return false;

    /* Stopped is a real engine barrier: decoder/vout teardown and its input
     * events have completed. Keep the listener attached through that barrier
     * and require exact equality, rather than relying on a short duplicate
     * observation window. */
    pthread_mutex_lock(&completion->lock);
    bool exact = completion->count == exact_terminal_count;
    pthread_mutex_unlock(&completion->lock);
    return exact;
}

static bool stop_player(libvlc_media_player_t *player)
{
    libvlc_media_player_stop_async(player);
    return wait_for_state(player, libvlc_Stopped, 5000);
}

struct opening_barrier
{
    pthread_mutex_t lock;
    pthread_cond_t changed;
    bool opened;
};

static void on_opening(const libvlc_event_t *event, void *opaque)
{
    (void)event;
    struct opening_barrier *barrier = opaque;
    pthread_mutex_lock(&barrier->lock);
    barrier->opened = true;
    pthread_cond_broadcast(&barrier->changed);
    pthread_mutex_unlock(&barrier->lock);
}

static bool play_through_opening(libvlc_media_player_t *player)
{
    struct opening_barrier barrier = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    libvlc_event_manager_t *events = libvlc_media_player_event_manager(player);
    if (libvlc_event_attach(events, libvlc_MediaPlayerOpening,
                            on_opening, &barrier) != 0)
        return false;
    bool started = libvlc_media_player_play(player) == 0;
    struct timespec deadline;
    deadline_after(&deadline, 5000);
    pthread_mutex_lock(&barrier.lock);
    while (started && !barrier.opened)
        if (pthread_cond_timedwait(&barrier.changed, &barrier.lock,
                                   &deadline) == ETIMEDOUT)
            break;
    bool opened = started && barrier.opened;
    pthread_mutex_unlock(&barrier.lock);
    libvlc_event_detach(events, libvlc_MediaPlayerOpening,
                        on_opening, &barrier);
    pthread_cond_destroy(&barrier.changed);
    pthread_mutex_destroy(&barrier.lock);
    return opened;
}

static int run_vmem_atomic_rebind_case(const char *path)
{
    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    libvlc_media_t *media = vlc == NULL ? NULL
        : libvlc_media_new_path(path);
    libvlc_media_player_t *player = media == NULL ? NULL
        : libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
        return 2;

    struct vmem_context a = { .submission_status = 0 };
    struct vmem_context b = { .submission_status = 0 };
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &a) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&a.status_count, 1, 5000))
    {
        fprintf(stderr, "vmem atomic rebind failed at initial A\n");
        return 1;
    }

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    /* Force the exact combined publisher's allocation failure. It must return
     * ENOMEM and leave the complete A generation as the next Open snapshot;
     * falling back to sequential legacy setters here would create a mixed
     * tuple and is forbidden. */
    swiftvlc_vmem_configuration_registry_ForceAllocationFailure(
        player->vmem_configuration, true);
    int forced_result = swiftvlc_libvlc_video_set_callbacks_atomic(
        player, vmem_lock, NULL, vmem_display, vmem_display_submission,
        vmem_setup_ex, vmem_cleanup, &b);
    swiftvlc_vmem_configuration_registry_ForceAllocationFailure(
        player->vmem_configuration, false);
    const swiftvlc_vmem_configuration *preserved =
        swiftvlc_vmem_configuration_registry_Acquire(
            player->vmem_configuration);
    bool preserved_a = preserved != NULL
        && preserved->lock == vmem_lock
        && preserved->display == vmem_display
        && preserved->display_status == vmem_display_submission
        && preserved->setup_ex == vmem_setup_ex
        && preserved->cleanup == vmem_cleanup
        && preserved->opaque == &a;
    swiftvlc_vmem_configuration_Release(preserved);
    if (forced_result != -ENOMEM || !preserved_a)
        return 1;
#endif

    /* Rebind while A is open. A keeps its immutable generation through Close;
     * the next Open gets all of B, never B's opaque with A's cleanup/status. */
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &b) != 0
     || swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display, NULL, vmem_setup_ex,
            vmem_cleanup, &a) != -EINVAL
     || !stop_player(player)
     || atomic_load_explicit(&a.setup_count, memory_order_relaxed) != 1
     || atomic_load_explicit(&a.cleanup_count, memory_order_relaxed) != 1
     || atomic_load_explicit(&b.setup_count, memory_order_relaxed) != 0
     || atomic_load_explicit(&b.cleanup_count, memory_order_relaxed) != 0)
    {
        fprintf(stderr,
                "vmem atomic rebind failed at A close A=%u/%u B=%u/%u\n",
                atomic_load_explicit(&a.setup_count, memory_order_relaxed),
                atomic_load_explicit(&a.cleanup_count, memory_order_relaxed),
                atomic_load_explicit(&b.setup_count, memory_order_relaxed),
                atomic_load_explicit(&b.cleanup_count, memory_order_relaxed));
        return 1;
    }

    if (libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&b.status_count, 1, 5000))
    {
        fprintf(stderr, "vmem atomic rebind failed opening B B=%u/%u status=%u\n",
                atomic_load_explicit(&b.setup_count, memory_order_relaxed),
                atomic_load_explicit(&b.cleanup_count, memory_order_relaxed),
                atomic_load_explicit(&b.status_count, memory_order_relaxed));
        return 1;
    }

    /* Clear is one disabled generation. The already-open B still receives its
     * matching cleanup; a racing/new Open can only see fully disabled. */
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, NULL, NULL, NULL, NULL, NULL, NULL, NULL) != 0
     || !stop_player(player)
     || atomic_load_explicit(&b.setup_count, memory_order_relaxed) != 1
     || atomic_load_explicit(&b.cleanup_count, memory_order_relaxed) != 1)
    {
        fprintf(stderr, "vmem atomic rebind failed clearing B B=%u/%u\n",
                atomic_load_explicit(&b.setup_count, memory_order_relaxed),
                atomic_load_explicit(&b.cleanup_count, memory_order_relaxed));
        return 1;
    }

    /* Invalid partial publication above did not mutate B, and disabled Open
     * must not invoke any old callback. Wait for this playback to start:
     * otherwise stop_player can observe the previous Stopped state while the
     * new input is still starting, then a later rebind leaks into that input.
     * Opening is latched because disabled output may never reach Playing. */
    if (!play_through_opening(player)
     || !stop_player(player)
     || atomic_load_explicit(&a.setup_count, memory_order_relaxed) != 1
     || atomic_load_explicit(&b.setup_count, memory_order_relaxed) != 1)
    {
        fprintf(stderr, "vmem atomic rebind failed disabled Open A=%u B=%u\n",
                atomic_load_explicit(&a.setup_count, memory_order_relaxed),
                atomic_load_explicit(&b.setup_count, memory_order_relaxed));
        return 1;
    }

    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &a) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&a.setup_count, 2, 5000)
     || !stop_player(player)
     || atomic_load_explicit(&a.setup_count, memory_order_relaxed) != 2
     || atomic_load_explicit(&a.cleanup_count, memory_order_relaxed) != 2)
    {
        fprintf(stderr, "vmem atomic rebind failed final A A=%u/%u status=%u\n",
                atomic_load_explicit(&a.setup_count, memory_order_relaxed),
                atomic_load_explicit(&a.cleanup_count, memory_order_relaxed),
                atomic_load_explicit(&a.status_count, memory_order_relaxed));
        return 1;
    }

    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    return 0;
}

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
enum {
    lifecycle_raw_width = 16,
    lifecycle_raw_height = 16,
    lifecycle_raw_frame_count = 2,
    lifecycle_raw_frame_size = lifecycle_raw_width * lifecycle_raw_height
                             * 3 / 2,
};

struct lifecycle_raw_stream
{
    unsigned char bytes[lifecycle_raw_frame_size * lifecycle_raw_frame_count];
};

struct lifecycle_fixture
{
    libvlc_instance_t *vlc;
    libvlc_media_t *media;
    libvlc_media_player_t *player;
    libvlc_event_manager_t *events;
    struct vmem_context vmem;
    struct completion completion;
    struct lifecycle_raw_stream raw;
    char raw_path[PATH_MAX];
};

/* Block one exact strict target after native commit has won but inside the
 * result-bearing vmem callback. The pre-commit barrier first parks the sole
 * vout render thread; only then is the module barrier enabled. Releasing the
 * commit barrier makes the target callback the next possible invocation, so
 * periodic RENDER_PICTURE_FORCED redisplay cannot satisfy this oracle. */
static bool await_exact_committed_submission(struct lifecycle_fixture *fixture,
                                             uint64_t request_id)
{
    if (!force_commit_barrier(fixture->player, true))
    {
        fprintf(stderr, "request %llu had no live commit barrier input\n",
                (unsigned long long)request_id);
        return false;
    }
    swiftvlc_next_frame_request_result_t result =
        swiftvlc_libvlc_media_player_request_next_frame(fixture->player,
                                                         request_id);
    if (result != swiftvlc_next_frame_request_accepted
     || !await_commit_barrier(fixture->player, 5000))
    {
        fprintf(stderr, "request %llu did not reach commit barrier result=%d\n",
                (unsigned long long)request_id, result);
        (void) force_commit_barrier(fixture->player, false);
        return false;
    }

    set_submission_barrier(&fixture->vmem, true);
    if (!force_commit_barrier(fixture->player, false)
     || !await_submission_barrier(&fixture->vmem, 5000))
    {
        fprintf(stderr,
                "request %llu did not reach exact module submission\n",
                (unsigned long long)request_id);
        set_submission_barrier(&fixture->vmem, false);
        return false;
    }
    return true;
}

static int lifecycle_fixture_open(struct lifecycle_fixture *fixture,
                                  const char *path)
{
    memset(fixture, 0, sizeof(*fixture));
    fixture->vmem.submission_status = 0;
    pthread_mutex_init(&fixture->vmem.submission_barrier_lock, NULL);
    pthread_cond_init(&fixture->vmem.submission_barrier_changed, NULL);
    pthread_mutex_init(&fixture->completion.lock, NULL);
    pthread_cond_init(&fixture->completion.changed, NULL);

    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    fixture->vlc = libvlc_new(3, arguments);
    fixture->media = fixture->vlc == NULL ? NULL
        : libvlc_media_new_path(path);
    fixture->player = fixture->media == NULL ? NULL
        : libvlc_media_player_new_from_media(fixture->vlc, fixture->media);
    if (fixture->player == NULL)
        return 2;
    fixture->events = libvlc_media_player_event_manager(fixture->player);
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            fixture->player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup,
            &fixture->vmem) != 0
     || libvlc_event_attach(fixture->events,
                            libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &fixture->completion) != 0
     || libvlc_media_player_play(fixture->player) != 0
     || !wait_for_state(fixture->player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&fixture->vmem.status_count, 1, 5000))
        return 1;
    libvlc_media_player_set_pause(fixture->player, 1);
    return wait_for_state(fixture->player, libvlc_Paused, 5000) ? 0 : 1;
}

static int lifecycle_fixture_open_raw(struct lifecycle_fixture *fixture)
{
    memset(fixture, 0, sizeof(*fixture));
    fixture->vmem.submission_status = 0;
    pthread_mutex_init(&fixture->vmem.submission_barrier_lock, NULL);
    pthread_cond_init(&fixture->vmem.submission_barrier_changed, NULL);
    pthread_mutex_init(&fixture->completion.lock, NULL);
    pthread_cond_init(&fixture->completion.changed, NULL);
    for (unsigned frame = 0; frame < lifecycle_raw_frame_count; ++frame)
    {
        unsigned char *pixels = fixture->raw.bytes
                              + frame * lifecycle_raw_frame_size;
        memset(pixels, 16 + frame * 40,
               lifecycle_raw_width * lifecycle_raw_height);
        memset(pixels + lifecycle_raw_width * lifecycle_raw_height, 128,
               lifecycle_raw_frame_size
             - lifecycle_raw_width * lifecycle_raw_height);
    }

    const char *temp_directory = getenv("TMPDIR");
    if (temp_directory == NULL || temp_directory[0] == '\0')
        temp_directory = "/tmp";
    int path_length = snprintf(fixture->raw_path, sizeof(fixture->raw_path),
                               "%s/swiftvlc-strict-eof-XXXXXX",
                               temp_directory);
    if (path_length < 0 || (size_t)path_length >= sizeof(fixture->raw_path))
        return 1;
    int raw_fd = mkstemp(fixture->raw_path);
    if (raw_fd < 0)
        return 1;
    size_t written = 0;
    while (written < sizeof(fixture->raw.bytes))
    {
        ssize_t result = write(raw_fd, fixture->raw.bytes + written,
                               sizeof(fixture->raw.bytes) - written);
        if (result <= 0)
        {
            close(raw_fd);
            unlink(fixture->raw_path);
            fixture->raw_path[0] = '\0';
            return 1;
        }
        written += (size_t)result;
    }
    if (close(raw_fd) != 0)
    {
        unlink(fixture->raw_path);
        fixture->raw_path[0] = '\0';
        return 1;
    }

    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show",
    };
    fixture->vlc = libvlc_new(3, arguments);
    fixture->media = fixture->vlc == NULL ? NULL
        : libvlc_media_new_path(fixture->raw_path);
    if (fixture->media != NULL)
    {
        libvlc_media_add_option(fixture->media, ":demux=rawvideo");
        libvlc_media_add_option(fixture->media, ":rawvid-width=16");
        libvlc_media_add_option(fixture->media, ":rawvid-height=16");
        libvlc_media_add_option(fixture->media, ":rawvid-chroma=I420");
        libvlc_media_add_option(fixture->media, ":rawvid-fps=25/1");
    }
    fixture->player = fixture->media == NULL ? NULL
        : libvlc_media_player_new_from_media(fixture->vlc, fixture->media);
    if (fixture->player == NULL)
        return 2;
    fixture->events = libvlc_media_player_event_manager(fixture->player);
    vlc_player_Lock(fixture->player->player);
    vlc_player_SetStartPaused(fixture->player->player, true);
    vlc_player_Unlock(fixture->player->player);
    int callback_result = swiftvlc_libvlc_video_set_callbacks_atomic(
            fixture->player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup,
            &fixture->vmem);
    int attach_result = libvlc_event_attach(
        fixture->events, libvlc_MediaPlayerFrameStepCompleted,
        on_completion, &fixture->completion);
    int play_result = callback_result == 0 && attach_result == 0
                    ? libvlc_media_player_play(fixture->player) : -1;
    bool paused = play_result == 0
               && wait_for_state(fixture->player, libvlc_Paused, 5000);
    bool submitted = paused
                  && await_atomic_at_least(&fixture->vmem.status_count,
                                           1, 5000);
    if (callback_result != 0 || attach_result != 0 || play_result != 0
     || !paused || !submitted)
    {
        fprintf(stderr,
                "raw EOF fixture failed callbacks=%d attach=%d play=%d "
                "paused=%d submitted=%d state=%d status-count=%u\n",
                callback_result, attach_result, play_result, paused, submitted,
                libvlc_media_player_get_state(fixture->player),
                atomic_load_explicit(&fixture->vmem.status_count,
                                     memory_order_relaxed));
        return 1;
    }
    return 0;
}

static void lifecycle_fixture_close(struct lifecycle_fixture *fixture)
{
    libvlc_event_detach(fixture->events,
                        libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &fixture->completion);
    libvlc_media_player_release(fixture->player);
    libvlc_media_release(fixture->media);
    libvlc_release(fixture->vlc);
    if (fixture->raw_path[0] != '\0')
        unlink(fixture->raw_path);
    free(fixture->vmem.pixels);
    pthread_cond_destroy(&fixture->completion.changed);
    pthread_mutex_destroy(&fixture->completion.lock);
    pthread_cond_destroy(&fixture->vmem.submission_barrier_changed);
    pthread_mutex_destroy(&fixture->vmem.submission_barrier_lock);
}

static bool lifecycle_exact_after_stop(struct lifecycle_fixture *fixture,
                                       uint64_t request_id)
{
    if (!wait_for_state(fixture->player, libvlc_Stopped, 5000)
     || check_committed_terminal(&fixture->completion, 1, request_id))
        return false;
    pthread_mutex_lock(&fixture->completion.lock);
    const bool exact = fixture->completion.count == 1;
    pthread_mutex_unlock(&fixture->completion.lock);
    return exact;
}

static int lifecycle_failure(int line)
{
    fprintf(stderr, "committed lifecycle failure at line=%d\n", line);
    return 1;
}

static int run_committed_terminal_lifecycle_case(const char *path)
{
    /* Post-claim/pre-terminal stop. The result-bearing vmem callback is the
     * exact module boundary: the input generation is already committed, but
     * no terminal can yet be queued. Stop detaches the input, repeated cancel
     * must remain false, and the old input drains one exact non-canceled result
     * before DEAD. Listener reentry sees the stopped player as unavailable. */
    struct lifecycle_fixture stopped;
    if (lifecycle_fixture_open(&stopped, path) != 0)
        return lifecycle_failure(__LINE__);
    arm_reentrant_request(&stopped.completion, stopped.player, 1200, 1201);
    if (!await_exact_committed_submission(&stopped, 1200))
        return lifecycle_failure(__LINE__);
    libvlc_media_player_stop_async(stopped.player);
    bool stop_cancel =
        swiftvlc_libvlc_media_player_cancel_next_frame_request(
            stopped.player, 1200);
    set_submission_barrier(&stopped.vmem, false);
    const bool stopped_exact = lifecycle_exact_after_stop(&stopped, 1200);
    const bool stopped_reentry = await_reentrant_result(
        &stopped.completion, swiftvlc_next_frame_request_unavailable);
    if (stop_cancel || !stopped_exact || !stopped_reentry)
    {
        pthread_mutex_lock(&stopped.completion.lock);
        fprintf(stderr,
                "post-claim stop cancel=%d exact=%d reentry=%d "
                "terminal-count=%u id=%llu status=%d state=%d\n",
                stop_cancel, stopped_exact, stopped_reentry,
                stopped.completion.count,
                (unsigned long long)stopped.completion.request_id,
                stopped.completion.status,
                libvlc_media_player_get_state(stopped.player));
        pthread_mutex_unlock(&stopped.completion.lock);
        return lifecycle_failure(__LINE__);
    }
    lifecycle_fixture_close(&stopped);

    /* The same pre-terminal ownership must cross media replacement, not just
     * explicit stop. The replacement API detaches A while the exact module
     * result is blocked; releasing it must deliver A rather than synthesize
     * ECANCELED from the now-NULL current input. */
    struct lifecycle_fixture replace_claim;
    if (lifecycle_fixture_open(&replace_claim, path) != 0)
        return lifecycle_failure(__LINE__);
    if (!await_exact_committed_submission(&replace_claim, 1205))
        return lifecycle_failure(__LINE__);
    libvlc_media_t *claim_replacement = libvlc_media_new_path(path);
    libvlc_media_player_set_media(replace_claim.player, claim_replacement);
    bool claim_replacement_cancel =
        swiftvlc_libvlc_media_player_cancel_next_frame_request(
            replace_claim.player, 1205);
    set_submission_barrier(&replace_claim.vmem, false);
    if (claim_replacement_cancel
     || !lifecycle_exact_after_stop(&replace_claim, 1205))
    {
        fprintf(stderr, "post-claim media replacement failed cancel=%d\n",
                claim_replacement_cancel);
        return lifecycle_failure(__LINE__);
    }
    libvlc_media_release(claim_replacement);
    lifecycle_fixture_close(&replace_claim);

    /* Queue-before-stop is distinct from the origin barrier above: the exact
     * result has entered the non-droppable lane, but the input consumer has
     * not popped it. input_Stop must preserve the queue and release the test
     * barrier without clearing or relabeling its strict member. */
    struct lifecycle_fixture queued_stop;
    if (lifecycle_fixture_open(&queued_stop, path) != 0)
        return lifecycle_failure(__LINE__);
    struct source_request_handle queued_stop_handle =
        capture_source_request(queued_stop.player);
    if (!set_terminal_pop_barrier(queued_stop_handle, true)
     || swiftvlc_libvlc_media_player_request_next_frame(
            queued_stop.player, 1206) != swiftvlc_next_frame_request_accepted)
        return lifecycle_failure(__LINE__);
    queued_stop_handle = capture_source_request(queued_stop.player);
    if (!await_terminal_pop_barrier(queued_stop_handle, 5000))
        return lifecycle_failure(__LINE__);
    libvlc_media_player_stop_async(queued_stop.player);
    bool queued_stop_cancel =
        swiftvlc_libvlc_media_player_cancel_next_frame_request(
            queued_stop.player, 1206);
    set_terminal_pop_barrier(queued_stop_handle, false);
    if (queued_stop_cancel
     || !lifecycle_exact_after_stop(&queued_stop, 1206))
    {
        fprintf(stderr, "queued-terminal stop failed cancel=%d\n",
                queued_stop_cancel);
        return lifecycle_failure(__LINE__);
    }
    lifecycle_fixture_close(&queued_stop);

    /* A fully queued terminal must also survive media replacement. Hold the
     * input consumer before pop, replace/detach the media, then release it.
     * The old exact result wins and no STOPPING cancellation is synthesized. */
    struct lifecycle_fixture replaced;
    if (lifecycle_fixture_open(&replaced, path) != 0)
        return lifecycle_failure(__LINE__);
    struct source_request_handle replacement_handle =
        capture_source_request(replaced.player);
    if (!set_terminal_pop_barrier(replacement_handle, true)
     || swiftvlc_libvlc_media_player_request_next_frame(replaced.player, 1210)
            != swiftvlc_next_frame_request_accepted)
        return lifecycle_failure(__LINE__);
    replacement_handle = capture_source_request(replaced.player);
    if (!await_terminal_pop_barrier(replacement_handle, 5000))
        return lifecycle_failure(__LINE__);
    libvlc_media_t *replacement = libvlc_media_new_path(path);
    arm_reentrant_request(&replaced.completion, replaced.player, 1210, 1211);
    libvlc_media_player_set_media(replaced.player, replacement);
    bool replacement_cancel =
        swiftvlc_libvlc_media_player_cancel_next_frame_request(
            replaced.player, 1210);
    set_terminal_pop_barrier(replacement_handle, false);
    if (replacement_cancel
     || !lifecycle_exact_after_stop(&replaced, 1210)
     || !await_reentrant_result(&replaced.completion,
                                swiftvlc_next_frame_request_unavailable))
    {
        fprintf(stderr, "queued-terminal media replacement failed cancel=%d\n",
                replacement_cancel);
        return lifecycle_failure(__LINE__);
    }
    libvlc_media_release(replacement);
    lifecycle_fixture_close(&replaced);

    /* In-transit means ControlPop removed the terminal and the input callback
     * is blocked on the player lock. Acknowledge retains its durable marker
     * until callback return, so stop observes commit and the event itself
     * remains the sole completion after the lock is released. */
    struct lifecycle_fixture transit;
    if (lifecycle_fixture_open(&transit, path) != 0)
        return lifecycle_failure(__LINE__);
    struct source_request_handle transit_handle =
        capture_source_request(transit.player);
    /* Let input initialization and output finish with the player lock free.
     * Holding it before a terminal is queued can block an earlier input event
     * and prevent the test from ever reaching its in-transit boundary. */
    if (!set_terminal_pop_barrier(transit_handle, true)
     || swiftvlc_libvlc_media_player_request_next_frame(transit.player, 1220)
            != swiftvlc_next_frame_request_accepted)
        return lifecycle_failure(__LINE__);
    transit_handle = capture_source_request(transit.player);
    if (!await_terminal_pop_barrier(transit_handle, 5000))
        return lifecycle_failure(__LINE__);
    libvlc_media_player_lock(transit.player);
    if (!set_terminal_pop_barrier(transit_handle, false)
     || !await_terminal_in_transit(transit_handle, 1220, 5000))
    {
        libvlc_media_player_unlock(transit.player);
        return lifecycle_failure(__LINE__);
    }
    libvlc_media_player_stop_async(transit.player);
    bool transit_cancel =
        swiftvlc_libvlc_media_player_cancel_next_frame_request(
            transit.player, 1220);
    libvlc_media_player_unlock(transit.player);
    if (transit_cancel || !lifecycle_exact_after_stop(&transit, 1220))
    {
        fprintf(stderr, "in-transit stop failed cancel=%d\n", transit_cancel);
        return lifecycle_failure(__LINE__);
    }
    lifecycle_fixture_close(&transit);

    /* The two-frame raw fixture starts paused after its first output. Let the
     * sole strict target complete output submission and enter the durable
     * terminal lane, then defer only ControlPop delivery. The nonblocking test
     * barrier still lets the input thread consume its coalesced EOS level and
     * leave MainLoop through the real drained-EOF branch. Run's post-End drain
     * must preserve the exact result rather than synthesize ECANCELED. */
    struct lifecycle_fixture eof;
    if (lifecycle_fixture_open_raw(&eof) != 0)
        return lifecycle_failure(__LINE__);
    struct source_request_handle eof_handle = capture_source_request(eof.player);
    if (!set_terminal_pop_barrier(eof_handle, true)
     || swiftvlc_libvlc_media_player_request_next_frame(eof.player, 1230)
            != swiftvlc_next_frame_request_accepted)
        return lifecycle_failure(__LINE__);
    eof_handle = capture_source_request(eof.player);
    if (!await_terminal_pop_barrier(eof_handle, 5000))
        return lifecycle_failure(__LINE__);
    eof_handle = capture_source_request(eof.player);
    if (eof_handle.input != NULL)
        input_ControlSetFrameNextNeedData(eof_handle.input, true);
    if (eof_handle.input == NULL
     || !await_natural_eof_quiescing(eof_handle, 5000))
    {
        input_thread_private_t *eof_priv = eof_handle.input == NULL ? NULL
                                           : input_priv(eof_handle.input);
        fprintf(stderr,
                "natural EOF did not leave MainLoop before target release "
                "state=%d stopped=%d eof=%d pending=%d need=%d empty=%d\n",
                eof_priv == NULL ? -1 : eof_priv->i_state,
                eof_priv == NULL ? -1 : eof_priv->is_stopped,
                eof_priv == NULL ? -1 : eof_priv->master->b_eof,
                eof_priv == NULL ? -1
                                 : eof_priv->frame_next_need_data_pending,
                eof_priv == NULL ? -1 : eof_priv->next_frame_need_data,
                eof_priv == NULL ? -1
                                 : es_out_IsEmpty(eof_priv->p_es_out));
        set_terminal_pop_barrier(eof_handle, false);
        return lifecycle_failure(__LINE__);
    }
    set_terminal_pop_barrier(eof_handle, false);
    if (!wait_for_state(eof.player, libvlc_Stopped, 5000))
    {
        fprintf(stderr, "natural EOF never reached stopped state\n");
        return lifecycle_failure(__LINE__);
    }
    if (check_committed_terminal(&eof.completion, 1, 1230))
    {
        fprintf(stderr, "natural EOF lost or relabelled its terminal\n");
        return lifecycle_failure(__LINE__);
    }
    pthread_mutex_lock(&eof.completion.lock);
    const bool eof_exact = eof.completion.count == 1;
    pthread_mutex_unlock(&eof.completion.lock);
    if (!eof_exact)
    {
        fprintf(stderr, "natural EOF delivered duplicate terminal\n");
        return lifecycle_failure(__LINE__);
    }
    lifecycle_fixture_close(&eof);
    return 0;
}

static int run_cancel_commit_race_case(const char *path)
{
    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    libvlc_media_t *media = vlc == NULL ? NULL
        : libvlc_media_new_path(path);
    libvlc_media_player_t *player = media == NULL ? NULL
        : libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
        return 2;

    struct vmem_context vmem = { .submission_status = 0 };
    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    pthread_mutex_init(&vmem.submission_barrier_lock, NULL);
    pthread_cond_init(&vmem.submission_barrier_changed, NULL);
    libvlc_event_manager_t *events =
        libvlc_media_player_event_manager(player);
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &vmem) != 0
     || libvlc_event_attach(events, libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &completion) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&vmem.status_count, 1, 5000))
        return 1;

    libvlc_media_player_set_pause(player, 1);
    if (!wait_for_state(player, libvlc_Paused, 5000)
     || swiftvlc_libvlc_media_player_request_next_frame(player, 1099)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 1, 1099,
                       swiftvlc_frame_step_status_success))
        return 1;
    const unsigned baseline = atomic_load_explicit(
        &vmem.status_count, memory_order_relaxed);

    /* Cancellation winner: freeze A at the exact pre-module commit boundary.
     * CANCEL clears native ownership and B is accepted immediately; releasing
     * the barrier lets A observe the lost arbitration, purge, and disappear
     * without invoking the result-bearing display callback even once. */
    libvlc_media_player_lock(player);
    bool barrier_ready = force_commit_barrier(player, true);
    swiftvlc_next_frame_request_result_t a_result =
        swiftvlc_libvlc_media_player_request_next_frame(player, 1100);
    barrier_ready = barrier_ready && await_commit_barrier(player, 5000);
    bool a_canceled = barrier_ready
        && swiftvlc_libvlc_media_player_cancel_next_frame_request(player,
                                                                  1100);
    swiftvlc_next_frame_request_result_t b_result =
        swiftvlc_libvlc_media_player_request_next_frame(player, 1101);
    (void) force_commit_barrier(player, false);
    libvlc_media_player_unlock(player);
    if (a_result != swiftvlc_next_frame_request_accepted
     || !barrier_ready || !a_canceled
     || b_result != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 2, 1100, -ECANCELED)
     || check_terminal(&completion, 3, 1101,
                       swiftvlc_frame_step_status_success)
     || !await_atomic_exact(&vmem.status_count, baseline + 1, 5000))
        return 1;

    /* Commit winner: keep the player lock held so delivery cannot clear A,
     * then wait for the exact result-bearing module invocation. CANCEL must
     * return false, must not remove the queued terminal, and B stays BUSY until
     * A's exact result is acknowledged. */
    libvlc_media_player_lock(player);
    swiftvlc_next_frame_request_result_t c_result =
        swiftvlc_libvlc_media_player_request_next_frame(player, 1102);
    bool c_submitted = await_atomic_exact(&vmem.status_count,
                                          baseline + 2, 5000);
    bool c_canceled =
        swiftvlc_libvlc_media_player_cancel_next_frame_request(player, 1102);
    swiftvlc_next_frame_request_result_t early_d =
        swiftvlc_libvlc_media_player_request_next_frame(player, 1103);
    libvlc_media_player_unlock(player);
    if (c_result != swiftvlc_next_frame_request_accepted || !c_submitted
     || c_canceled || early_d != swiftvlc_next_frame_request_busy
     || check_terminal(&completion, 4, 1102,
                       swiftvlc_frame_step_status_success)
     || swiftvlc_libvlc_media_player_request_next_frame(player, 1103)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 5, 1103,
                       swiftvlc_frame_step_status_success)
     || !await_atomic_exact(&vmem.status_count, baseline + 3, 5000))
        return 1;

    /* Stop/teardown is the quiescence barrier. The listener and result counter
     * remain live through it, so a late stale-A output or duplicate terminal
     * fails exact equality instead of escaping a timing window. */
    if (!stop_at_quiescence(player, &completion, 5)
     || atomic_load_explicit(&vmem.status_count, memory_order_relaxed)
            != baseline + 3)
        return 1;

    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);
    return 0;
}
#endif

static int run_deferred_error_reentry_case(const char *path)
{
    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    libvlc_media_t *media = vlc == NULL ? NULL
        : libvlc_media_new_path(path);
    libvlc_media_player_t *player = media == NULL ? NULL
        : libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
        return 2;

    struct vmem_context vmem = { .submission_status = 0 };
    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    libvlc_event_manager_t *events =
        libvlc_media_player_event_manager(player);
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &vmem) != 0
     || libvlc_event_attach(events, libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &completion) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&vmem.status_count, 1, 5000))
        return 1;

    libvlc_media_player_set_pause(player, 1);
    if (!wait_for_state(player, libvlc_Paused, 5000))
        return 1;

    /* The source checker binds every decoder/es_out strict error site to
     * input_ControlPushFrameNextDisplayed. Park SET at the real ordered
     * ControlPop boundary, withdraw it under lock_control, and inject that
     * exact production lane. This avoids a synthetic model while proving the
     * listener and its reentrant request run after all input locks unwind. */
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    struct source_request_handle gate = capture_source_request(player);
    if (gate.input == NULL)
        return 1;
    input_ControlForceFrameNextStrictSetPopBarrier(gate.input, true);
#endif
    arm_reentrant_request(&completion, player, 1200, 1201);
    swiftvlc_next_frame_request_result_t first_result =
        swiftvlc_libvlc_media_player_request_next_frame(player, 1200);
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (first_result != swiftvlc_next_frame_request_accepted
     || !input_ControlFrameNextStrictSetPopWaiting(gate.input))
    {
        for (unsigned attempt = 0; attempt < 500
             && !input_ControlFrameNextStrictSetPopWaiting(gate.input);
             ++attempt)
            sleep_milliseconds(10);
    }
    if (first_result != swiftvlc_next_frame_request_accepted
     || !input_ControlFrameNextStrictSetPopWaiting(gate.input))
    {
        input_ControlForceFrameNextStrictSetPopBarrier(gate.input, false);
        return 1;
    }
    libvlc_media_player_lock(player);
    struct source_request_handle first = {
        .input = player->player->input != NULL
               ? player->player->input->thread : NULL,
        .generation = player->player->strict_frame_request_generation,
    };
    bool first_owned = withdraw_strict_set_for_deferred_probe(first, 1200);
    if (first_owned)
        input_ControlPushFrameNextDisplayed(first.input, 1200,
                                            first.generation, -EBUSY,
                                            VLC_TICK_INVALID, -1.0, 1);
    libvlc_media_player_unlock(player);
    if (!first_owned)
    {
        input_ControlForceFrameNextStrictSetPopBarrier(gate.input, false);
        return 1;
    }
#else
    if (first_result != swiftvlc_next_frame_request_accepted)
        return 1;
#endif
    int first_terminal = check_terminal(&completion, 1, 1200, -EBUSY);
    if (first_terminal
     || !await_reentrant_result(&completion,
                                swiftvlc_next_frame_request_accepted))
    {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        input_ControlForceFrameNextStrictSetPopBarrier(gate.input, false);
#endif
        return 1;
    }
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    bool second_waiting = false;
    for (unsigned attempt = 0; attempt < 500; ++attempt)
    {
        if (input_ControlFrameNextStrictSetPopWaiting(gate.input))
        {
            second_waiting = true;
            break;
        }
        sleep_milliseconds(10);
    }
    if (!second_waiting)
    {
        input_ControlForceFrameNextStrictSetPopBarrier(gate.input, false);
        return 1;
    }
    libvlc_media_player_lock(player);
    struct source_request_handle second = {
        .input = player->player->input != NULL
               ? player->player->input->thread : NULL,
        .generation = player->player->strict_frame_request_generation,
    };
    bool second_owned = player->player->strict_frame_request_id == 1201
                     && withdraw_strict_set_for_deferred_probe(second, 1201);
    if (second_owned)
        input_ControlPushFrameNextDisplayed(second.input, 1201,
                                            second.generation, -EBUSY,
                                            VLC_TICK_INVALID, -1.0, 1);
    input_ControlForceFrameNextStrictSetPopBarrier(gate.input, false);
    libvlc_media_player_unlock(player);
    if (!second_owned)
        return 1;
#endif
    if (check_terminal(&completion, 2, 1201, -EBUSY)
     || !stop_at_quiescence(player, &completion, 2))
        return 1;

    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);
    return 0;
}

static int vmem_submission_failure(libvlc_media_player_t *player,
                                   struct vmem_context *vmem,
                                   struct completion *completion,
                                   uint64_t request_id, unsigned baseline,
                                   int line)
{
    pthread_mutex_lock(&completion->lock);
    unsigned terminals = completion->count;
    pthread_mutex_unlock(&completion->lock);
    fprintf(stderr,
            "vmem request=%llu failed at line=%d state=%d baseline=%u "
            "locks=%u displays=%u submissions=%u terminals=%u\n",
            (unsigned long long)request_id, line,
            libvlc_media_player_get_state(player), baseline,
            atomic_load_explicit(&vmem->lock_count, memory_order_relaxed),
            atomic_load_explicit(&vmem->display_count, memory_order_relaxed),
            atomic_load_explicit(&vmem->status_count, memory_order_relaxed),
            terminals);
    return 1;
}

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
static int run_terminal_overflow_case(const char *path)
{
    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    libvlc_media_t *media = vlc == NULL ? NULL
        : libvlc_media_new_path(path);
    libvlc_media_player_t *player = media == NULL ? NULL
        : libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
        return 2;

    struct vmem_context vmem = { .submission_status = 0 };
    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    unsigned baseline = 0;
    libvlc_event_manager_t *events =
        libvlc_media_player_event_manager(player);
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &vmem) != 0
     || libvlc_event_attach(events, libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &completion) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&vmem.status_count, 1, 5000))
        return vmem_submission_failure(player, &vmem, &completion, 990, baseline, __LINE__);

    libvlc_media_player_set_pause(player, 1);
    /* Finish an ordinary in-flight output before arming allocation failure and
     * counting the two fault/recovery submissions. Paused alone is not an
     * acknowledged output boundary. */
    if (!wait_for_state(player, libvlc_Paused, 5000)
     || swiftvlc_libvlc_media_player_request_next_frame(player, 989)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 1, 989,
                       swiftvlc_frame_step_status_success))
        return vmem_submission_failure(player, &vmem, &completion, 990, baseline, __LINE__);
    baseline = atomic_load_explicit(
        &vmem.status_count, memory_order_relaxed);

    /* This toggles the exact input queue's private allocator-failure branch;
     * no stand-alone ring model is involved. The already accepted request must
     * receive one allocation-free EOVERFLOW terminal, the input must remain
     * alive, and the slot must be immediately reusable after delivery. */
    if (!force_terminal_allocation_failure(player, true)
     || swiftvlc_libvlc_media_player_request_next_frame(player, 990)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 2, 990, -EOVERFLOW)
     || !force_terminal_allocation_failure(player, false)
     || swiftvlc_libvlc_media_player_request_next_frame(player, 991)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 3, 991,
                       swiftvlc_frame_step_status_success)
     || !await_atomic_exact(&vmem.status_count, baseline + 2, 5000)
     || !stop_at_quiescence(player, &completion, 3)
     || atomic_load_explicit(&vmem.status_count, memory_order_relaxed)
            != baseline + 2)
        return vmem_submission_failure(player, &vmem, &completion, 990, baseline, __LINE__);

    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);
    return 0;
}
#endif

static int run_vmem_submission_case(const char *path, uint64_t request_id,
                                    bool install_status_callback,
                                    bool install_legacy_display,
                                    int expected_status)
{
    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    if (vlc == NULL)
        return 2;
    libvlc_media_t *media = libvlc_media_new_path(path);
    libvlc_media_player_t *player = media == NULL ? NULL
        : libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
        return 2;

    struct vmem_context vmem = {
        .lock_count = 0,
        .display_count = 0,
        .status_count = 0,
        .submission_status = -EIO,
    };
    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    unsigned before_strict = 0;
    if (install_status_callback)
    {
        if (swiftvlc_libvlc_video_set_callbacks_atomic(
                player, vmem_lock, NULL,
                install_legacy_display ? vmem_display : NULL,
                vmem_display_submission, vmem_setup_ex, vmem_cleanup,
                &vmem) != 0)
            return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);
    }
    else
    {
        libvlc_video_set_callbacks(player, vmem_lock, NULL,
                                   install_legacy_display ? vmem_display
                                                          : NULL,
                                   &vmem);
        libvlc_video_set_format_callbacks(player, vmem_setup, vmem_cleanup);
    }

    libvlc_event_manager_t *events =
        libvlc_media_player_event_manager(player);
    atomic_uint *submission_counter = install_status_callback
        ? &vmem.status_count
        : install_legacy_display ? &vmem.display_count : &vmem.lock_count;
    if (libvlc_event_attach(events, libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &completion) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(submission_counter, 1, 5000))
        return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);

    /* Legacy void/NULL-display modes remain active for ordinary playback.
     * Only strict completion fails closed when submission is unproven. */
    libvlc_media_player_set_pause(player, 1);
    if (!wait_for_state(player, libvlc_Paused, 5000))
        return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);
    /* Paused is a player state, not a completed video-output submission.
     * An ordinary picture already in flight can still enter the callback.
     * A completed control request gives us an acknowledged output boundary
     * before measuring the exact mixed burst below. Check its real result too;
     * do not replace exact counts with a tolerance or a settling sleep. */
    if (swiftvlc_libvlc_media_player_request_next_frame(player,
                                                      request_id + 2000)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 1, request_id + 2000, expected_status))
        return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);
    before_strict =
        atomic_load_explicit(submission_counter, memory_order_relaxed);

    if (install_status_callback)
    {
        /* A rejecting result-bearing output still has to settle standards on
         * both sides exactly once and release/rebind the observer after its
         * tail. The strict target alone carries the exact -EIO result. */
        libvlc_media_player_lock(player);
        libvlc_media_player_next_frame(player);
        swiftvlc_next_frame_request_result_t accepted =
            swiftvlc_libvlc_media_player_request_next_frame(player,
                                                             request_id);
        libvlc_media_player_next_frame(player);
        libvlc_media_player_unlock(player);
        if (accepted != swiftvlc_next_frame_request_accepted
         || check_terminal(&completion, 2, request_id, expected_status)
         || !await_atomic_exact(submission_counter, before_strict + 3, 5000)
         || swiftvlc_libvlc_media_player_request_next_frame(
                player, request_id + 1000)
                != swiftvlc_next_frame_request_accepted
         || check_terminal(&completion, 3, request_id + 1000,
                           expected_status)
         || !await_atomic_exact(submission_counter, before_strict + 4, 5000))
            return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);
    }
    else if (swiftvlc_libvlc_media_player_request_next_frame(player,
                                                              request_id)
                != swiftvlc_next_frame_request_accepted
          || check_terminal(&completion, 2, request_id, expected_status)
          || atomic_load_explicit(submission_counter, memory_order_relaxed)
                != before_strict + 1)
        return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);

    const unsigned exact_terminals = install_status_callback ? 3 : 2;
    const unsigned exact_submissions = before_strict
        + (install_status_callback ? 4 : 1);
    if (!stop_at_quiescence(player, &completion, exact_terminals)
     || atomic_load_explicit(submission_counter, memory_order_relaxed)
            != exact_submissions)
        return vmem_submission_failure(player, &vmem, &completion, request_id, before_strict, __LINE__);
    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);
    return 0;
}

struct raw_stream_context
{
    unsigned char *bytes;
    size_t size;
    atomic_size_t offset;
    atomic_size_t limit;
    size_t max_read;
    long read_delay_ms;
};

static int raw_stream_open(void *opaque, void **data, uint64_t *size)
{
    struct raw_stream_context *context = opaque;
    atomic_store_explicit(&context->offset, 0, memory_order_release);
    if (atomic_load_explicit(&context->limit, memory_order_relaxed) == 0)
        atomic_store_explicit(&context->limit, context->size,
                              memory_order_release);
    *data = context;
    *size = UINT64_MAX;
    return 0;
}

static ptrdiff_t raw_stream_read(void *opaque, unsigned char *buffer,
                                 size_t length)
{
    struct raw_stream_context *context = opaque;
    size_t offset = atomic_load_explicit(&context->offset,
                                         memory_order_acquire);
    size_t limit = atomic_load_explicit(&context->limit,
                                        memory_order_acquire);
    size_t remaining = limit > offset ? limit - offset : 0;
    if (length > remaining)
        length = remaining;
    if (context->max_read != 0 && length > context->max_read)
        length = context->max_read;
    if (length != 0 && context->read_delay_ms != 0)
        sleep_milliseconds(context->read_delay_ms);
    memcpy(buffer, context->bytes + offset, length);
    atomic_store_explicit(&context->offset, offset + length,
                          memory_order_release);
    return (ptrdiff_t)length;
}

static int raw_stream_seek(void *opaque, uint64_t offset)
{
    struct raw_stream_context *context = opaque;
    if (offset > context->size)
        return -1;
    atomic_store_explicit(&context->offset, (size_t)offset,
                          memory_order_release);
    return 0;
}

static void raw_stream_close(void *opaque)
{
    (void) opaque;
}

static int run_unknown_length_case(uint64_t request_id)
{
    enum { width = 16, height = 16, frame_count = 250 };
    const size_t frame_size = width * height * 3u / 2u;
    struct raw_stream_context raw = {
        .bytes = malloc(frame_size * frame_count),
        .size = frame_size * frame_count,
    };
    if (raw.bytes == NULL)
        return 2;
    for (unsigned frame = 0; frame < frame_count; ++frame)
    {
        unsigned char *pixels = raw.bytes + frame * frame_size;
        memset(pixels, (int)(16 + frame % 200), width * height);
        memset(pixels + width * height, 128, frame_size - width * height);
    }

    const char *arguments[] = {
        "--no-audio", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    libvlc_media_t *media = vlc == NULL ? NULL
        : libvlc_media_new_callbacks(raw_stream_open, raw_stream_read,
                                     raw_stream_seek, raw_stream_close, &raw);
    if (media == NULL)
        return 2;
    libvlc_media_add_option(media, ":demux=rawvideo");
    libvlc_media_add_option(media, ":rawvid-width=16");
    libvlc_media_add_option(media, ":rawvid-height=16");
    libvlc_media_add_option(media, ":rawvid-chroma=I420");
    libvlc_media_add_option(media, ":rawvid-fps=25/1");

    libvlc_media_player_t *player =
        libvlc_media_player_new_from_media(vlc, media);
    struct vmem_context vmem = { .submission_status = 0 };
    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    libvlc_event_manager_t *events = player == NULL ? NULL
        : libvlc_media_player_event_manager(player);
    if (player == NULL
     || swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup, &vmem) != 0
     || libvlc_event_attach(events, libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &completion) != 0
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000)
     || !await_atomic_at_least(&vmem.status_count, 1, 5000))
        return 1;

    libvlc_media_player_set_pause(player, 1);
    swiftvlc_next_frame_request_result_t request_result =
        wait_for_state(player, libvlc_Paused, 5000)
            ? swiftvlc_libvlc_media_player_request_next_frame(player,
                                                               request_id)
            : swiftvlc_next_frame_request_unavailable;
    int terminal_result = request_result == swiftvlc_next_frame_request_accepted
        ? check_terminal(&completion, 1, request_id,
                         swiftvlc_frame_step_status_success) : 1;
    if (request_result != swiftvlc_next_frame_request_accepted
     || terminal_result)
    {
        int player_state = libvlc_media_player_get_state(player);
        pthread_mutex_lock(&completion.lock);
        fprintf(stderr,
                "unknown-length row request=%d count=%u id=%llu status=%d "
                "time=%lld position=%f state=%d\n",
                request_result, completion.count,
                (unsigned long long)completion.request_id,
                completion.status, (long long)completion.time_us,
                completion.position, player_state);
        pthread_mutex_unlock(&completion.lock);
        return 1;
    }

    pthread_mutex_lock(&completion.lock);
    bool exact_time_without_position = completion.history[0].time_us >= 0
                                    && completion.history[0].position == -1.0;
    pthread_mutex_unlock(&completion.lock);

    bool quiesced = stop_at_quiescence(player, &completion, 1);
    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);
    free(raw.bytes);
    if (!exact_time_without_position || !quiesced)
        fprintf(stderr,
                "unknown-length result exact=%d quiesced=%d time=%lld "
                "position=%f\n",
                exact_time_without_position, quiesced,
                (long long)completion.history[0].time_us,
                completion.history[0].position);
    return exact_time_without_position && quiesced ? 0 : 1;
}

enum static_filter_case
{
    static_filter_drop,
    static_filter_legacy_pending,
    static_filter_expansion,
    static_filter_cancel_rebind,
};

static int run_static_filter_case(uint64_t request_id,
                                  enum static_filter_case test_case)
{
    enum { width = 16, height = 16 };
    const bool legacy_pending = test_case == static_filter_legacy_pending;
    const bool expansion = legacy_pending
                        || test_case == static_filter_expansion;
    const bool cancel_rebind = test_case == static_filter_cancel_rebind;
    /* Exact raw inventories: 25->1 needs timestamps 0...1s for the initial
     * plus one requested output; cancel/rebind needs 0...3s for L-before,
     * L-after and B. The 1->4 row needs exactly two raw timestamps. */
    const unsigned frame_count = legacy_pending ? 1u
                               : expansion ? 2u
                               : cancel_rebind ? 75u : 25u;
    const size_t frame_size = width * height * 3u / 2u;
    struct raw_stream_context raw = {
        .bytes = malloc(frame_size * frame_count),
        .size = frame_size * frame_count,
        .limit = frame_size * frame_count,
        /* A one-picture read plus a bounded delay keeps the synthetic stream
         * from reaching EOF before --start-paused is observed. It also makes
         * every decoded-input-to-final-output relationship visible to the
         * source-linked NEXT submission oracle. */
        .max_read = frame_size,
        .read_delay_ms = 30,
    };
    if (raw.bytes == NULL)
        return 2;
    for (unsigned frame = 0; frame < frame_count; ++frame)
    {
        unsigned char *pixels = raw.bytes + frame * frame_size;
        memset(pixels, (int)(16 + frame * 7u), width * height);
        memset(pixels + width * height, 128, frame_size - width * height);
    }

    const char *arguments[] = {
        "--no-audio", "--aout=dummy",
        "--no-video-title-show", "--no-drop-late-frames",
        expansion ? "--deinterlace=1" : "--video-filter=fps",
        expansion ? "--deinterlace-mode=bob" : "--fps-fps=1/1",
    };
    libvlc_instance_t *vlc = libvlc_new(6, arguments);
    libvlc_media_t *media = vlc == NULL ? NULL
        : libvlc_media_new_callbacks(raw_stream_open, raw_stream_read,
                                     raw_stream_seek, raw_stream_close,
                                     &raw);
    if (media == NULL)
        return 2;
    libvlc_media_add_option(media, ":demux=rawvideo");
    libvlc_media_add_option(media, ":rawvid-width=16");
    libvlc_media_add_option(media, ":rawvid-height=16");
    libvlc_media_add_option(media, ":rawvid-chroma=I420");
    libvlc_media_add_option(media, expansion ? ":rawvid-fps=1/1"
                                             : ":rawvid-fps=25/1");

    libvlc_media_player_t *player =
        libvlc_media_player_new_from_media(vlc, media);
    struct vmem_context vmem = {
        .lock_count = 0,
        .display_count = 0,
        .status_count = 0,
        .submission_status = 0,
    };
    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    libvlc_event_manager_t *events = player == NULL ? NULL
        : libvlc_media_player_event_manager(player);
    if (player == NULL)
        return 2;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    struct core_step_order core_order = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    vlc_player_listener_id *core_listener =
        attach_core_step_listener(player, &core_order);
    if (core_listener == NULL)
        return 2;
#endif
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup,
            &vmem) != 0)
        return 1;

    int attach_result = libvlc_event_attach(
        events, libvlc_MediaPlayerFrameStepCompleted,
        on_completion, &completion);
    int play_result = attach_result == 0 ? libvlc_media_player_play(player)
                                         : -1;
    bool playing = play_result == 0
                && wait_for_state(player, libvlc_Playing, 5000);
    bool initial_submission = playing
                           && await_atomic_at_least(&vmem.status_count, 1,
                                                    5000);
    if (initial_submission)
        libvlc_media_player_set_pause(player, 1);
    bool paused = initial_submission
               && wait_for_state(player, libvlc_Paused, 5000);
    if (attach_result != 0 || play_result != 0 || !paused
     || !initial_submission)
    {
        fprintf(stderr,
                "static setup attach=%d play=%d playing=%d paused=%d "
                "status=%u state=%d\n",
                attach_result, play_result, playing, paused,
                atomic_load_explicit(&vmem.status_count,
                                     memory_order_relaxed),
                libvlc_media_player_get_state(player));
        return 1;
    }

    unsigned terminal_count = 0;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    uint64_t expected_submissions = frame_next_submission_count(player);
    pthread_mutex_lock(&core_order.lock);
    unsigned expected_core_events = core_order.count;
    pthread_mutex_unlock(&core_order.lock);
#else
    unsigned expected_submissions = atomic_load_explicit(
        &vmem.status_count, memory_order_relaxed);
#endif
    uint64_t eof_request_id = request_id + 1;
    if (legacy_pending)
    {
        /* One bob input has already displayed its first output and retained
         * its second in the static chain. A standalone traditional request
         * must receive exactly one final-output status before any strict
         * request exists; stopping afterward proves strict admission is not a
         * rescue mechanism for the consumed legacy member. */
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        const uint64_t before_legacy = frame_next_submission_count(player);
        bool before_in_flight;
        uint64_t before_empty_attempts;
        if (!frame_next_terminal_probe(player, &before_in_flight,
                                       &before_empty_attempts)
         || before_in_flight)
            return 1;
        set_submission_barrier(&vmem, true);
        const struct source_request_handle legacy_handle =
            capture_source_request(player);
        pthread_mutex_lock(&core_order.lock);
        const unsigned before_core = core_order.count;
        pthread_mutex_unlock(&core_order.lock);
#else
        const unsigned before_legacy = atomic_load_explicit(
            &vmem.status_count, memory_order_relaxed);
#endif
        libvlc_media_player_next_frame(player);
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        const bool reached_submission = await_submission_barrier(&vmem, 5000);
        bool terminal_in_flight = false;
        uint64_t empty_attempts = 0;
        const bool sampled = frame_next_terminal_probe(
            player, &terminal_in_flight, &empty_attempts);
        /* The single filter-pending member needs no replacement decode, so a
         * paused input would otherwise have no reason to probe natural EOF
         * while the output callback is parked. Drive the same level-triggered
         * need-data edge used by real replacement work; this adds no frame
         * request and makes the producer-quiescence race deterministic. */
        if (reached_submission && legacy_handle.input != NULL)
            input_ControlSetFrameNextNeedData(legacy_handle.input, true);
        const bool eof_waited = reached_submission && sampled
            && await_frame_next_empty_while_terminal_count(
                player, before_empty_attempts + 1, 5000);
        const bool eof_crossed = legacy_handle.input != NULL
            && input_ControlFrameNextNaturalEofQuiescing(
                legacy_handle.input);
        set_submission_barrier(&vmem, false);
        if (!reached_submission || !terminal_in_flight || !eof_waited
         || eof_crossed)
        {
            fprintf(stderr,
                    "legacy terminal barrier submission=%d in-flight=%d "
                    "eof-waited=%d eof-crossed=%d empty=%llu/%llu\n",
                    reached_submission, terminal_in_flight, eof_waited,
                    eof_crossed, (unsigned long long)empty_attempts,
                    (unsigned long long)(before_empty_attempts + 1));
            return 1;
        }
#endif
        if (
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
             !await_frame_next_submission_count(player, before_legacy + 1,
                                                 5000)
          || !check_core_legacy_order(&core_order, before_core, 1,
                                      VLC_SUCCESS)
#else
             !await_atomic_exact(&vmem.status_count, before_legacy + 1, 5000)
#endif
           )
        {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
            fprintf(stderr,
                    "standalone legacy pending next=%llu target=%llu\n",
                    (unsigned long long)frame_next_submission_count(player),
                    (unsigned long long)(before_legacy + 1));
            dump_core_step_order(&core_order, before_core);
#endif
            return 1;
        }
        expected_submissions = before_legacy + 1;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        expected_core_events = before_core + 1;
#endif
    }
    else if (expansion)
    {
        /* Forced bob deinterlacing turns one raw input into two final outputs.
         * At the paused boundary one output is already filter-pending, so the
         * remaining input yields exactly three NEXT submissions. First commit
         * and acknowledge L-before,S. Only then enqueue L-after. This is the
         * deterministic form of the audited race: the strict terminal's
         * priority lane may overtake a globally later ordinary legacy SET.
         * The final-output observer must survive acknowledgement long enough
         * to account that filter-pending tail as SUCCESS, not a speculative
         * raw-FIFO EOF status. */
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        uint64_t before_burst = frame_next_submission_count(player);
        pthread_mutex_lock(&core_order.lock);
        unsigned before_core = core_order.count;
        pthread_mutex_unlock(&core_order.lock);
#else
        unsigned before_burst = atomic_load_explicit(
            &vmem.status_count, memory_order_relaxed);
#endif
        libvlc_media_player_lock(player);
        libvlc_media_player_next_frame(player);
        if (swiftvlc_libvlc_media_player_request_next_frame(
                player, request_id) != swiftvlc_next_frame_request_accepted)
            return 1;
        libvlc_media_player_unlock(player);
        if (check_terminal(&completion, 1, request_id,
                           swiftvlc_frame_step_status_success))
            return 1;

        /* The strict observer has now received its completion acknowledgement
         * while no legacy member is yet present in the vout aggregate. */
        libvlc_media_player_next_frame(player);
        if (
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
             !await_frame_next_submission_count(player, before_burst + 3,
                                                 5000)
         || !check_core_mixed_order(&core_order, before_core, request_id,
                                    1, 1, VLC_SUCCESS, VLC_SUCCESS)
#else
             !await_atomic_exact(&vmem.status_count, before_burst + 3, 5000)
#endif
           )
        {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
            fprintf(stderr, "static expansion next=%llu target=%llu\n",
                    (unsigned long long)frame_next_submission_count(player),
                    (unsigned long long)(before_burst + 3));
            dump_core_step_order(&core_order, before_core);
#endif
            return 1;
        }
        expected_submissions = before_burst + 3;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        expected_core_events = before_core + 3;
#endif
        terminal_count = 1;
    }
    else if (cancel_rebind)
    {
        /* Slow one-frame raw reads make the 25:1 fps drop deterministic. Once
         * L-before submits, S is installed but still needs about 25 reads.
         * Cancel S, retain L-after, then bind B behind it immediately. */
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        uint64_t before_burst = frame_next_submission_count(player);
        pthread_mutex_lock(&core_order.lock);
        unsigned before_core = core_order.count;
        pthread_mutex_unlock(&core_order.lock);
#else
        unsigned before_burst = atomic_load_explicit(
            &vmem.status_count, memory_order_relaxed);
#endif
        libvlc_media_player_lock(player);
        libvlc_media_player_next_frame(player);
        swiftvlc_next_frame_request_result_t accepted =
            swiftvlc_libvlc_media_player_request_next_frame(player,
                                                             request_id);
        libvlc_media_player_next_frame(player);
        libvlc_media_player_unlock(player);
        if (accepted != swiftvlc_next_frame_request_accepted
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
         || !await_frame_next_submission_count(player, before_burst + 1, 5000)
#else
         || !await_atomic_exact(&vmem.status_count, before_burst + 1, 5000)
#endif
           )
        {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
            fprintf(stderr, "static cancel prefix next=%llu target=%llu\n",
                    (unsigned long long)frame_next_submission_count(player),
                    (unsigned long long)(before_burst + 1));
            dump_core_step_order(&core_order, before_core);
#endif
            return 1;
        }

        const uint64_t rebound_id = request_id + 100;
        libvlc_media_player_lock(player);
        bool canceled =
            swiftvlc_libvlc_media_player_cancel_next_frame_request(
                player, request_id);
        swiftvlc_next_frame_request_result_t rebound =
            swiftvlc_libvlc_media_player_request_next_frame(player,
                                                             rebound_id);
        libvlc_media_player_unlock(player);
        if (!canceled || rebound != swiftvlc_next_frame_request_accepted
         || check_terminal(&completion, 1, request_id, -ECANCELED)
         || check_terminal(&completion, 2, rebound_id,
                           swiftvlc_frame_step_status_success)
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
         || !await_frame_next_submission_count(player, before_burst + 3,
                                                10000)
         || !check_core_cancel_rebind_order(&core_order, before_core,
                                            request_id, rebound_id)
#else
         || !await_atomic_exact(&vmem.status_count, before_burst + 3, 10000)
#endif
           )
        {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
            fprintf(stderr, "static cancel/rebind next=%llu target=%llu\n",
                    (unsigned long long)frame_next_submission_count(player),
                    (unsigned long long)(before_burst + 3));
            dump_core_step_order(&core_order, before_core);
#endif
            return 1;
        }
        expected_submissions = before_burst + 3;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        expected_core_events = before_core + 4;
#endif
        terminal_count = 2;
        eof_request_id = rebound_id + 1;
    }
    else
    {
        /* 25fps -> 1fps consumes roughly 25 raw pictures before producing
         * the next final output. The strict request must replenish one raw at
         * a time until success rather than wedge when each filter call drops. */
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        uint64_t before_drop = frame_next_submission_count(player);
        pthread_mutex_lock(&core_order.lock);
        unsigned before_core = core_order.count;
        pthread_mutex_unlock(&core_order.lock);
#else
        unsigned before_drop = atomic_load_explicit(
            &vmem.status_count, memory_order_relaxed);
#endif
        if (swiftvlc_libvlc_media_player_request_next_frame(
                player, request_id) != swiftvlc_next_frame_request_accepted
         || check_terminal(&completion, 1, request_id,
                           swiftvlc_frame_step_status_success)
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
         || !await_frame_next_submission_count(player, before_drop + 1, 5000)
         || !check_core_mixed_order(&core_order, before_core, request_id,
                                    0, 0, VLC_SUCCESS, VLC_SUCCESS)
#else
         || !await_atomic_exact(&vmem.status_count, before_drop + 1, 5000)
#endif
           )
        {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
            fprintf(stderr,
                    "static drop next=%llu target=%llu status=%u "
                    "display=%u locks=%u\n",
                    (unsigned long long)frame_next_submission_count(player),
                    (unsigned long long)(before_drop + 1),
                    atomic_load_explicit(&vmem.status_count,
                                         memory_order_relaxed),
                    atomic_load_explicit(&vmem.display_count,
                                         memory_order_relaxed),
                    atomic_load_explicit(&vmem.lock_count,
                                         memory_order_relaxed));
            dump_core_step_order(&core_order, before_core);
#endif
            return 1;
        }
        expected_submissions = before_drop + 1;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        expected_core_events = before_core + 1;
#endif
        terminal_count = 1;
    }

    /* The tiny source is now drained. Except for the deliberately pure-legacy
     * row, this request proves all final no-output observations settle and
     * release batch ownership. */
    if (!legacy_pending
     && (swiftvlc_libvlc_media_player_request_next_frame(player,
                                                          eof_request_id)
            != swiftvlc_next_frame_request_accepted
      || check_terminal(&completion, terminal_count + 1, eof_request_id,
                        swiftvlc_frame_step_status_no_frame)))
    {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        fprintf(stderr, "static EOF terminal failed request=%llu\n",
                (unsigned long long)eof_request_id);
        dump_core_step_order(&core_order, 0);
#endif
        return 1;
    }
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (!legacy_pending
     && !check_core_mixed_order(&core_order, expected_core_events,
                                eof_request_id, 0, 0, VLC_SUCCESS,
                                swiftvlc_frame_step_status_no_frame))
    {
        fprintf(stderr, "static EOF core order failed request=%llu\n",
                (unsigned long long)eof_request_id);
        dump_core_step_order(&core_order, 0);
        return 1;
    }
    if (!legacy_pending)
        ++expected_core_events;
#endif

    const unsigned expected_terminal_count = terminal_count
                                           + (legacy_pending ? 0 : 1);
    if (!stop_at_quiescence(player, &completion, expected_terminal_count)
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
     || frame_next_submission_count(player) != expected_submissions
     || !await_core_step_count(&core_order, expected_core_events, 0)
#else
     || atomic_load_explicit(&vmem.status_count, memory_order_relaxed)
            != expected_submissions
#endif
       )
    {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        fprintf(stderr,
                "static quiescence mismatch next=%llu/%llu core=%u\n",
                (unsigned long long)frame_next_submission_count(player),
                (unsigned long long)expected_submissions,
                expected_core_events);
        dump_core_step_order(&core_order, 0);
#endif
        return 1;
    }
    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    detach_core_step_listener(player, core_listener);
    pthread_cond_destroy(&core_order.changed);
    pthread_mutex_destroy(&core_order.lock);
#endif
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&vmem.submission_barrier_changed);
    pthread_mutex_destroy(&vmem.submission_barrier_lock);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);
    free(raw.bytes);
    return 0;
}

int main(int argc, char **argv)
{
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    /* Keep the teardown durability race executable independently from the
     * longer burst/filter qualification. This is intentionally source-linked:
     * it uses the real input ownership hooks and the corrected archive, not a
     * disconnected model. */
    if (argc == 3 && strcmp(argv[1], "--lifecycle-only") == 0)
    {
        if (swiftvlc_libvlc_pip_extensions_version()
            != SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION)
            return 1;
        if (run_committed_terminal_lifecycle_case(argv[2]) != 0)
        {
            fprintf(stderr,
                    "committed terminal was lost/relabelled across input teardown\n");
            return 1;
        }
        printf("PASS committed terminal stop+replacement+EOF durability\n");
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--deferred-only") == 0)
    {
        if (run_deferred_error_reentry_case(argv[2]) != 0)
            return 1;
        printf("PASS deferred strict error reentry\n");
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--unknown-only") == 0)
    {
        if (run_unknown_length_case(950) != 0)
            return 1;
        printf("PASS unknown-length strict timing\n");
        return 0;
    }
    if (argc == 3 && strncmp(argv[1], "--static-", 9) == 0)
    {
        enum static_filter_case filter_case;
        uint64_t request_id;
        if (strcmp(argv[1], "--static-drop") == 0)
            filter_case = static_filter_drop, request_id = 960;
        else if (strcmp(argv[1], "--static-expansion") == 0)
            filter_case = static_filter_expansion, request_id = 970;
        else if (strcmp(argv[1], "--static-legacy") == 0)
            filter_case = static_filter_legacy_pending, request_id = 965;
        else if (strcmp(argv[1], "--static-cancel") == 0)
            filter_case = static_filter_cancel_rebind, request_id = 980;
        else
            return 2;
        if (run_static_filter_case(request_id, filter_case) != 0)
            return 1;
        printf("PASS %s\n", argv[1] + 2);
        return 0;
    }
#endif

    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <seekable-vod>\n", argv[0]);
        return 2;
    }

    if (swiftvlc_libvlc_pip_extensions_version()
        != SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION)
    {
        fprintf(stderr,
                "strict frame-step extension version is not %u\n",
                (unsigned)SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION);
        return 1;
    }

    const char *arguments[] = {
        "--vout=dummy", "--aout=dummy", "--no-video-title-show"
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    if (vlc == NULL)
        return 2;
    libvlc_media_player_t *empty = libvlc_media_player_new(vlc);
    if (empty == NULL)
        return 2;
    swiftvlc_libvlc_video_set_display_status_callback(empty, NULL);
    if (swiftvlc_libvlc_media_player_request_next_frame(empty, 1)
        != swiftvlc_next_frame_request_unavailable)
    {
        fprintf(stderr, "empty player did not reject as unavailable\n");
        return 1;
    }
    libvlc_media_player_release(empty);

    libvlc_media_t *media = libvlc_media_new_path(argv[1]);
    if (media == NULL)
        return 2;
    libvlc_media_player_t *player =
        libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
        return 2;

#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    struct core_step_order core_order = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    vlc_player_listener_id *core_listener =
        attach_core_step_listener(player, &core_order);
    if (core_listener == NULL)
        return 2;
#endif

    struct vmem_context main_vmem = {
        .lock_count = 0,
        .display_count = 0,
        .status_count = 0,
        .submission_status = 0,
    };
    if (swiftvlc_libvlc_video_set_callbacks_atomic(
            player, vmem_lock, NULL, vmem_display,
            vmem_display_submission, vmem_setup_ex, vmem_cleanup,
            &main_vmem) != 0)
        return 1;

    struct completion completion = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    libvlc_event_manager_t *events =
        libvlc_media_player_event_manager(player);
    if (libvlc_event_attach(events, libvlc_MediaPlayerFrameStepCompleted,
                            on_completion, &completion) != 0)
        return 2;

    /* A media-assigned player still has no running input before play. It must
     * reject synchronously and must never promise an orphan terminal event. */
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 2)
            != swiftvlc_next_frame_request_unavailable)
        return 1;
    sleep_milliseconds(50);
    pthread_mutex_lock(&completion.lock);
    bool preplay_was_inert = completion.count == 0;
    pthread_mutex_unlock(&completion.lock);
    if (!preplay_was_inert)
        return 1;

    if (swiftvlc_libvlc_media_player_request_next_frame(player, 0)
        != swiftvlc_next_frame_request_invalid
     || libvlc_media_player_play(player) != 0
     || !wait_for_state(player, libvlc_Playing, 5000))
        return 1;

    /* With A active, PAUSE uses the ordinary lane while RESUME owns A's
     * CANCEL+reset reserved capacity. B is a post-control barrier: it can arm
     * only after the reset is consumed and must see the final PLAYING state.
     * This catches the old reserved-priority inversion without accepting the
     * preexisting Playing state as a false-positive wait result. */
    libvlc_media_player_lock(player);
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 90)
            != swiftvlc_next_frame_request_accepted
     || swiftvlc_libvlc_media_player_request_next_frame(player, 89)
            != swiftvlc_next_frame_request_busy)
        return 1;
    libvlc_media_player_set_pause(player, 1);
    libvlc_media_player_set_pause(player, 0);
    libvlc_media_player_unlock(player);
    if (check_terminal(&completion, 1, 90, -ECANCELED)
     || request_after_reset_barrier(player, 91)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 2, 91,
                       swiftvlc_frame_step_status_paused_for_retry)
     || !wait_for_state(player, libvlc_Paused, 5000))
    {
        fprintf(stderr, "pause/resume global order was not preserved\n");
        return 1;
    }

    /* More than the fixed FIFO capacity of consecutive seeks must coalesce
     * in the ordinary lane rather than fill the two-entry reserved lane or
     * stop the input. Request 92 executes after all seek controls and is the
     * observed barrier proving the input remained live. */
    for (unsigned index = 0; index < 256; ++index)
    {
        float position = 0.10f + (float)(index % 32) / 320.0f;
        if (libvlc_media_player_set_position(player, position, true) != 0)
        {
            fprintf(stderr, "rapid seek %u overflowed the control stream\n",
                    index);
            return 1;
        }
    }
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 92)
            != swiftvlc_next_frame_request_accepted
     || check_terminal(&completion, 3, 92,
                       swiftvlc_frame_step_status_success))
        return 1;
    unsigned target = 3;

    /* Cancellation is ID-matched, idempotent for mismatches, terminal once,
     * and makes the native slot reusable before returning. Reuse the same ID
     * twice without yielding the player lock: private generations must keep
     * the two accepted requests independent. */
    libvlc_media_player_lock(player);
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 200)
            != swiftvlc_next_frame_request_accepted
     || swiftvlc_libvlc_media_player_cancel_next_frame_request(player, 201)
     || !swiftvlc_libvlc_media_player_cancel_next_frame_request(player, 200)
     || swiftvlc_libvlc_media_player_cancel_next_frame_request(player, 200)
     || swiftvlc_libvlc_media_player_request_next_frame(player, 200)
            != swiftvlc_next_frame_request_accepted
     || !swiftvlc_libvlc_media_player_cancel_next_frame_request(player, 200))
        return 1;
    libvlc_media_player_unlock(player);
    target += 2;
    if (check_cancel_pair(&completion, target, 200))
        return 1;

    /* A causal seek must terminal A while the reset gate is still closed. A
     * listener which reenters with B therefore sees BUSY, and the dedicated
     * reset barrier prevents a later B from overtaking the seek. */
    arm_reentrant_request(&completion, player, 400, 401);
    libvlc_media_player_lock(player);
    libvlc_time_t seek_time = libvlc_media_player_get_time(player);
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 400)
            != swiftvlc_next_frame_request_accepted
     || libvlc_media_player_set_time(player, seek_time < 0 ? 0 : seek_time,
                                     false) != 0)
        return 1;
    libvlc_media_player_unlock(player);
    target++;
    if (check_terminal(&completion, target, 400, -ECANCELED)
     || !await_reentrant_busy(&completion)
     || request_after_reset_barrier(player, 401)
            != swiftvlc_next_frame_request_accepted
     || !swiftvlc_libvlc_media_player_cancel_next_frame_request(player, 401))
        return 1;
    target++;
    if (check_terminal(&completion, target, 401, -ECANCELED))
        return 1;

    /* Resume has the same causal ordering guarantee. Its cancellation
     * callback cannot sneak B in ahead of PLAYING_S. */
    arm_reentrant_request(&completion, player, 410, 411);
    arm_nested_pause(&completion, player, 410);
    libvlc_media_player_lock(player);
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 410)
            != swiftvlc_next_frame_request_accepted)
        return 1;
    libvlc_media_player_set_pause(player, 0);
    libvlc_media_player_unlock(player);
    target++;
    if (check_terminal(&completion, target, 410, -ECANCELED)
     || !await_reentrant_busy(&completion)
     || !await_nested_pause(&completion)
     || request_after_reset_barrier(player, 411)
            != swiftvlc_next_frame_request_accepted)
        return 1;
    target++;
    if (check_terminal(&completion, target, 411,
                       swiftvlc_frame_step_status_success)
     || !wait_for_state(player, libvlc_Paused, 5000))
        return 1;

    /* Establish an exact video-PTS baseline on the A/V fixture. Audio is the
     * default master, so success must normalize the target video timestamp
     * rather than copy a stale generic best-source point. */
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 299)
            != swiftvlc_next_frame_request_accepted)
        return 1;
    target++;
    if (check_terminal(&completion, target, 299,
                       swiftvlc_frame_step_status_success))
        return 1;
    pthread_mutex_lock(&completion.lock);
    int64_t baseline_video_time = completion.history[target - 1].time_us;
    pthread_mutex_unlock(&completion.lock);

    /* Mix the strict member into a traditional burst on both sides. The
     * source-linked terminal-pop barrier delays delivery without holding the
     * player lock needed by normal input/vout progress. All nine concrete
     * NEXT submissions therefore complete before the correlated target is
     * delivered, proving that its captured PTS cannot be overwritten by the
     * four trailing legacy pictures. */
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    struct source_request_handle mixed_handle = capture_source_request(player);
    if (!set_terminal_pop_barrier(mixed_handle, true))
        return 1;
    uint64_t mixed_submission_baseline =
        frame_next_submission_count(player);
    pthread_mutex_lock(&core_order.lock);
    unsigned mixed_core_baseline = core_order.count;
    pthread_mutex_unlock(&core_order.lock);
#endif
    libvlc_media_player_lock(player);
    for (unsigned index = 0; index < 4; ++index)
        libvlc_media_player_next_frame(player);
    swiftvlc_next_frame_request_result_t mixed_result =
        swiftvlc_libvlc_media_player_request_next_frame(player, 300);
    for (unsigned index = 0; index < 4; ++index)
        libvlc_media_player_next_frame(player);
    libvlc_media_player_unlock(player);
    if (mixed_result != swiftvlc_next_frame_request_accepted)
    {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        set_terminal_pop_barrier(mixed_handle, false);
#endif
        return 1;
    }
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    bool mixed_outputs_completed = mixed_submission_baseline != UINT64_MAX
        && mixed_submission_baseline <= UINT64_MAX - 9
        && await_frame_next_submission_count(
               player, mixed_submission_baseline + 9, 5000);
    bool mixed_delivery_deferred =
        await_terminal_pop_barrier(mixed_handle, 5000);
    set_terminal_pop_barrier(mixed_handle, false);
#else
    bool mixed_outputs_completed = true;
    bool mixed_delivery_deferred = true;
#endif
    if (!mixed_outputs_completed || !mixed_delivery_deferred)
    {
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
        (void) await_core_step_count(&core_order,
                                     mixed_core_baseline + 9, 1000);
        pthread_mutex_lock(&core_order.lock);
        unsigned observed_core = core_order.count - mixed_core_baseline;
        pthread_mutex_unlock(&core_order.lock);
        fprintf(stderr,
                "mixed burst did not submit all nine outputs next=%llu/%llu "
                "origin=%llu core=%u vmem=%u\n",
                (unsigned long long)frame_next_submission_count(player),
                (unsigned long long)(mixed_submission_baseline + 9),
                (unsigned long long)terminal_origin_count(mixed_handle),
                observed_core,
                atomic_load_explicit(&main_vmem.status_count,
                                     memory_order_relaxed));
#endif
        return 1;
    }
    target++;
    if (check_terminal(&completion, target, 300,
                       swiftvlc_frame_step_status_success))
        return 1;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (!check_core_mixed_order(&core_order, mixed_core_baseline, 300,
                                4, 4, VLC_SUCCESS, VLC_SUCCESS))
    {
        fprintf(stderr,
                "legacy-before/strict/legacy-after callback order changed\n");
        return 1;
    }
#endif

    pthread_mutex_lock(&completion.lock);
    int64_t mixed_target_time = completion.history[target - 1].time_us;
    pthread_mutex_unlock(&completion.lock);
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    pthread_mutex_lock(&core_order.lock);
    unsigned after_burst_core_baseline = core_order.count;
    pthread_mutex_unlock(&core_order.lock);
    uint64_t after_burst_submission_baseline =
        frame_next_submission_count(player);
#endif
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 301)
            != swiftvlc_next_frame_request_accepted)
        return 1;
    target++;
    if (check_terminal(&completion, target, 301,
                       swiftvlc_frame_step_status_success))
        return 1;
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (!await_frame_next_submission_count(
            player, after_burst_submission_baseline + 1, 5000)
     || !check_core_mixed_order(&core_order, after_burst_core_baseline, 301,
                                0, 0, VLC_SUCCESS, VLC_SUCCESS))
        return 1;
#endif
    pthread_mutex_lock(&completion.lock);
    int64_t after_burst_time = completion.history[target - 1].time_us;
    pthread_mutex_unlock(&completion.lock);

    /* twosec.mp4 is CFR 25fps. Each interval spans exactly four legacy
     * pictures plus its strict target: 5 * 40ms. Adjacent-frame or broad-band
     * acceptance would not prove target-correlated timestamp capture. */
    int64_t first_delta = mixed_target_time - baseline_video_time;
    int64_t second_delta = after_burst_time - mixed_target_time;
    if (first_delta != 200000 || second_delta != 200000)
    {
        fprintf(stderr,
                "strict target timing was not PTS-correlated: %lld/%lld us\n",
                (long long)first_delta, (long long)second_delta);
        return 1;
    }

    /* First capture this exact build/fixture's precise 500ms seek landing with
     * no outstanding burst ownership. Container edit offsets make a literal
     * guessed 520ms value less authoritative than this clean control row. */
    libvlc_media_player_lock(player);
    int clean_seek_result = libvlc_media_player_set_time(player, 500, false);
    swiftvlc_next_frame_request_result_t clean_seek_request =
        clean_seek_result == 0
            ? swiftvlc_libvlc_media_player_request_next_frame(player, 879)
            : swiftvlc_next_frame_request_unavailable;
    libvlc_media_player_unlock(player);
    if (clean_seek_result != 0
     || clean_seek_request != swiftvlc_next_frame_request_accepted)
        return 1;
    target++;
    if (check_terminal(&completion, target, 879,
                       swiftvlc_frame_step_status_success))
        return 1;
    pthread_mutex_lock(&completion.lock);
    int64_t clean_post_seek_time = completion.history[target - 1].time_us;
    pthread_mutex_unlock(&completion.lock);

    /* Near EOF, queue resident legacy work followed by a strict target and a
     * trailing legacy suffix that cannot be decoded. Draining must remove the
     * entire missing aggregate suffix, not just strict request 880. Otherwise
     * those stale legacy counts survive the following seek and consume its
     * pictures before request 881. */
    libvlc_media_player_lock(player);
    if (libvlc_media_player_set_position(player, 0.99, false) != 0)
        return 1;
    for (unsigned index = 0; index < 8; ++index)
        libvlc_media_player_next_frame(player);
    if (swiftvlc_libvlc_media_player_request_next_frame(player, 880)
            != swiftvlc_next_frame_request_accepted)
        return 1;
    for (unsigned index = 0; index < 8; ++index)
        libvlc_media_player_next_frame(player);
    libvlc_media_player_unlock(player);
    target++;
    if (check_terminal(&completion, target, 880,
                       swiftvlc_frame_step_status_no_frame))
        return 1;

    libvlc_media_player_lock(player);
    if (libvlc_media_player_set_time(player, 500, false) != 0
     || swiftvlc_libvlc_media_player_request_next_frame(player, 881)
            != swiftvlc_next_frame_request_accepted)
        return 1;
    libvlc_media_player_unlock(player);
    target++;
    if (check_terminal(&completion, target, 881,
                       swiftvlc_frame_step_status_success))
        return 1;
    pthread_mutex_lock(&completion.lock);
    int64_t post_eof_seek_time = completion.history[target - 1].time_us;
    pthread_mutex_unlock(&completion.lock);
    /* Exact equality with the clean control landing rejects even one stale
     * aggregate member consuming a post-seek picture. A broad time band would
     * let that one-frame accounting error pass. */
    if (post_eof_seek_time != clean_post_seek_time)
    {
        fprintf(stderr,
                "drained frame counts crossed seek: clean=%lld after=%lld us\n",
                (long long)clean_post_seek_time,
                (long long)post_eof_seek_time);
        return 1;
    }

    /* Sequential strict bursts cover the final MR !8180 countdown path. Keep
     * stepping to EOF to cover its drained/EOF regression as well. Equal PTS
     * values are intentionally legal; correlation, not PTS inequality,
     * provides exactly-once completion. */
    uint64_t request_id = 200;
    bool reached_eof = false;
    for (unsigned step = 0; step < 300; ++step)
    {
        request_id += (step == 0 ? 0 : 1); /* first iteration reuses ID 200 */
        if (swiftvlc_libvlc_media_player_request_next_frame(player, request_id)
            != swiftvlc_next_frame_request_accepted)
            return 1;
        target++;
        if (!await_count(&completion, target, 5000))
            return 1;

        pthread_mutex_lock(&completion.lock);
        int status = completion.status;
        uint64_t completed_id = completion.request_id;
        int64_t time_us = completion.time_us;
        double position = completion.position;
        pthread_mutex_unlock(&completion.lock);
        if (completed_id != request_id)
            return 1;
        if (status == swiftvlc_frame_step_status_no_frame)
        {
            reached_eof = true;
            break;
        }
        if (status != swiftvlc_frame_step_status_success || time_us < 0
         || position < 0.0 || position > 1.0)
            return 1;
    }
    if (!reached_eof)
    {
        fprintf(stderr, "strict stepping did not reach EOF\n");
        return 1;
    }

    /* Request-id zero retains the legacy API and never emits the additive
     * strict event. */
    pthread_mutex_lock(&completion.lock);
    unsigned before_standard = completion.count;
    pthread_mutex_unlock(&completion.lock);
    libvlc_media_player_next_frame(player);
    bool standard_was_inert =
        stop_at_quiescence(player, &completion, before_standard);

    libvlc_event_detach(events, libvlc_MediaPlayerFrameStepCompleted,
                        on_completion, &completion);
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    detach_core_step_listener(player, core_listener);
    pthread_cond_destroy(&core_order.changed);
    pthread_mutex_destroy(&core_order.lock);
#endif
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    pthread_cond_destroy(&completion.changed);
    pthread_mutex_destroy(&completion.lock);

    if (!standard_was_inert)
        return 1;
    if (run_vmem_atomic_rebind_case(argv[1]) != 0)
    {
        fprintf(stderr,
                "atomic vmem Open/rebind/clear lifetime contract failed\n");
        return 1;
    }
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (run_terminal_overflow_case(argv[1]) != 0)
    {
        fprintf(stderr,
                "terminal allocation failure did not deliver exact EOVERFLOW\n");
        return 1;
    }
    if (run_committed_terminal_lifecycle_case(argv[1]) != 0)
    {
        fprintf(stderr,
                "committed terminal was lost/relabelled across input teardown\n");
        return 1;
    }
    if (run_cancel_commit_race_case(argv[1]) != 0)
    {
        fprintf(stderr,
                "cancel/commit arbitration leaked output or lost a terminal\n");
        return 1;
    }
#endif
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (run_deferred_error_reentry_case(argv[1]) != 0)
    {
        fprintf(stderr,
                "strict es_out error listener reentered before lock unwind\n");
        return 1;
    }
#endif
    if (run_vmem_submission_case(argv[1], 900, true, true, -EIO) != 0)
    {
        fprintf(stderr, "vmem rejection did not fail strict with -EIO\n");
        return 1;
    }
    if (run_vmem_submission_case(argv[1], 901, false, true, -ENOTSUP) != 0)
    {
        fprintf(stderr, "legacy void vmem was not strict-fail-closed\n");
        return 1;
    }
    if (run_vmem_submission_case(argv[1], 902, false, false, -ENOTSUP) != 0)
    {
        fprintf(stderr, "NULL-display vmem compatibility regressed\n");
        return 1;
    }
    if (run_unknown_length_case(950) != 0)
    {
        fprintf(stderr,
                "unknown-length strict step lost exact time or invented position\n");
        return 1;
    }
#ifdef SWIFTVLC_SOURCE_LINKED_PROBE
    if (run_static_filter_case(960, static_filter_drop) != 0)
    {
        fprintf(stderr,
                "fps drop replacement did not settle strict exact-once\n");
        return 1;
    }
    if (run_static_filter_case(970, static_filter_expansion) != 0)
    {
        fprintf(stderr,
                "filter-pending 1-to-N EOF output was miscounted\n");
        return 1;
    }
    if (run_static_filter_case(965, static_filter_legacy_pending) != 0)
    {
        fprintf(stderr,
                "standalone legacy filter-pending output lost its status\n");
        return 1;
    }
    if (run_static_filter_case(980, static_filter_cancel_rebind) != 0)
    {
        fprintf(stderr,
                "mixed cancel did not preserve legacy tail/rebind strict B\n");
        return 1;
    }
#endif
    printf("PASS strict frame-step burst+EOF completions=%u\n", target);
    return 0;
}
