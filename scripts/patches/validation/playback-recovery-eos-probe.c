/* Inject subsystem failure/recovery notifications into the integrated input
 * event handler, then let real paused media resume and reach natural EOF.
 * This tests terminal public events, including another unresolved decoder and
 * an unrelated demux failure. Output-factory recovery call sites are covered
 * separately by the compiled source contracts. */
#include "config.h"
#include <vlc_common.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media.h>
#include <vlc/libvlc_media_player.h>
#include <vlc/libvlc_events.h>
#include "libvlc_internal.h"
#include "media_player_internal.h"
#include "src/player/input.c"
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static atomic_int stopping, failures, last_failure;

static void on_event(const libvlc_event_t *event, void *data)
{
    (void) data;
    if (event->type == libvlc_MediaPlayerEncounteredError)
    {
        atomic_store(&last_failure, event->u.media_player_encountered_error.failure);
        atomic_fetch_add(&failures, 1);
    }
    else
        atomic_store(&stopping, event->u.media_player_media_stopping.reason);
}

static int run(libvlc_instance_t *instance, const char *path, int scenario)
{
    atomic_store(&stopping, -1);
    atomic_store(&failures, 0);
    atomic_store(&last_failure, -1);
    libvlc_media_player_t *mp = libvlc_media_player_new(instance);
    libvlc_media_t *media = libvlc_media_new_path(path);
    if (!mp || !media) abort();
    libvlc_media_add_option(media, ":start-paused");
    libvlc_media_player_set_media(mp, media);
    libvlc_event_manager_t *em = libvlc_media_player_event_manager(mp);
    if (libvlc_event_attach(em, libvlc_MediaPlayerEncounteredError, on_event, NULL) ||
        libvlc_event_attach(em, libvlc_MediaPlayerMediaStopping, on_event, NULL))
        abort();
    if (libvlc_media_player_play(mp) != 0) abort();
    unsigned wait;
    for (wait = 0; wait < 5000; ++wait)
    {
        if (libvlc_media_player_get_state(mp) == libvlc_Paused) break;
        usleep(1000);
    }
    if (wait == 5000)
    {
        fprintf(stderr, "pause timeout\n");
        abort();
    }
    /* Paused local media cannot reach EOF until this probe resumes it. No
     * other caller changes its lifetime while the events are injected. */
    vlc_player_Lock(mp->player);
    struct vlc_player_input *input = mp->player->input;
    if (!input) abort();
    input_thread_t *thread = input->thread;
    vlc_player_Unlock(mp->player);
    struct vlc_input_event fail = {
        .type = INPUT_EVENT_FAILURE, .failure = VLC_INPUT_FAILURE_RENDERER,
    };
    struct vlc_input_event recover = {
        .type = INPUT_EVENT_RECOVERY, .failure = VLC_INPUT_FAILURE_RENDERER,
    };
    input_thread_Events(thread, &fail, input);
    if (scenario == 2) input_thread_Events(thread, &fail, input);
    if (scenario == 3)
    {
        fail.failure = VLC_INPUT_FAILURE_DEMUX;
        input_thread_Events(thread, &fail, input);
    }
    if (scenario != 1) input_thread_Events(thread, &recover, input);
    libvlc_media_player_set_pause(mp, 0);
    for (wait = 0; wait < 10000 && atomic_load(&stopping) == -1; ++wait)
        usleep(1000);
    int reason = atomic_load(&stopping);
    int count = atomic_load(&failures);
    int kind = atomic_load(&last_failure);
    int expected = scenario == 3 ? libvlc_playback_failure_demux
                                 : libvlc_playback_failure_renderer;
    bool passed = scenario == 0
                ? reason == libvlc_stopping_reason_eos && count == 0
                : reason == libvlc_stopping_reason_error && count == 1 && kind == expected;
    printf("%s scenario=%d reason=%d errors=%d kind=%d\n",
           passed ? "PASS" : "FAIL", scenario, reason, count, kind);
    libvlc_media_player_stop_async(mp);
    libvlc_media_player_release(mp);
    libvlc_media_release(media);
    return !passed;
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    const char *args[] = {"--no-audio", "--vout=dummy", "--quiet"};
    libvlc_instance_t *instance = libvlc_new(3, args);
    if (!instance) return 2;
    int failed = 0;
    for (int scenario = 0; scenario < 4; ++scenario)
        failed |= run(instance, argv[1], scenario);
    libvlc_release(instance);
    return failed;
}
