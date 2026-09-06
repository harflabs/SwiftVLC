/* Compile the integrated playlist implementation with a controlled lock
 * handoff. Only the final media-player start is stubbed: item selection,
 * generation arbitration, locks, and the worker are production VLC code.
 * No decoder, network, or timing lottery is needed to exercise this race. */
#include "config.h"
#include <vlc_common.h>
#include <vlc_threads.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media.h>
#include <vlc/libvlc_media_player.h>
#include "libvlc_internal.h"
#include "media_player_internal.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static _Atomic(vlc_mutex_t *) handoff_lock;
static pthread_t main_thread;
static atomic_bool armed, captured, proceed, completed;

static bool wait_for(atomic_bool *flag)
{
    for (unsigned i = 0; i < 3000; ++i)
    {
        if (atomic_load(flag)) return true;
        usleep(1000);
    }
    return false;
}

static void probe_unlock(vlc_mutex_t *mutex)
{
    vlc_mutex_unlock(mutex);
    if (mutex != atomic_load(&handoff_lock) ||
        pthread_equal(pthread_self(), main_thread)) return;
    if (atomic_exchange(&armed, false))
    {
        atomic_store(&captured, true);
        if (!wait_for(&proceed)) abort();
    }
    else if (atomic_load(&captured) && atomic_load(&proceed))
        atomic_store(&completed, true);
}

static int probe_play(libvlc_media_player_t *player)
{
    (void) player;
    return 0;
}
#define vlc_mutex_unlock probe_unlock
#define libvlc_media_player_play probe_play
#define libvlc_media_player_play_internal(player, ...) probe_play(player)
#include "lib/media_list_player.c"
#undef vlc_mutex_unlock
#undef libvlc_media_player_play
#undef libvlc_media_player_play_internal

enum operation { mode_only, explicit_stop, explicit_selection };

static bool run(libvlc_instance_t *instance, libvlc_playback_mode_t mode,
                enum operation operation, int initial, int expected)
{
    atomic_store(&captured, false);
    atomic_store(&proceed, false);
    atomic_store(&completed, false);
    libvlc_media_list_player_t *list = libvlc_media_list_player_new(instance);
    libvlc_media_list_t *media = libvlc_media_list_new();
    if (!list || !media) abort();
    for (int i = 0; i < 3; ++i)
    {
        libvlc_media_t *item = libvlc_media_new_location("file:///unused.mp4");
        if (!item || libvlc_media_list_add_media(media, item) != 0) abort();
        libvlc_media_release(item);
    }
    libvlc_media_list_player_set_media_list(list, media);
    if (libvlc_media_list_player_play_item_at_index(list, initial) != 0) abort();
    atomic_store(&handoff_lock, &list->mp_callback_lock);
    atomic_store(&armed, true);
    vlc_mutex_lock(&list->mp_callback_lock);
    list->seek_offset = 1;
    vlc_cond_signal(&list->seek_pending);
    vlc_mutex_unlock(&list->mp_callback_lock);
    if (!wait_for(&captured)) abort();

    libvlc_media_list_player_set_playback_mode(list, mode);
    if (operation == explicit_stop)
        libvlc_media_list_player_stop_async(list);
    else if (operation == explicit_selection &&
             libvlc_media_list_player_play_item_at_index(list, 1) != 0)
        abort();
    atomic_store(&proceed, true);
    if (!wait_for(&completed)) abort();
    lock_internal(list);
    int actual = list->current_playing_item_path
               ? list->current_playing_item_path[0] : -1;
    unlock(list);
    bool passed = actual == expected;
    printf("%s mode=%d operation=%d initial=%d expected=%d actual=%d\n",
           passed ? "PASS" : "FAIL", mode, operation, initial, expected, actual);
    atomic_store(&handoff_lock, NULL);
    libvlc_media_list_player_release(list);
    libvlc_media_list_release(media);
    return passed;
}

int main(void)
{
    main_thread = pthread_self();
    const char *args[] = {"--aout=dummy", "--vout=dummy", "--no-video"};
    libvlc_instance_t *instance = libvlc_new(3, args);
    if (!instance) return 2;
    bool passed = true;
    for (unsigned repetition = 0; repetition < 20; ++repetition)
    {
        passed &= run(instance, libvlc_playback_mode_default, mode_only, 0, 1);
        passed &= run(instance, libvlc_playback_mode_loop, mode_only, 2, 0);
        passed &= run(instance, libvlc_playback_mode_repeat, mode_only, 1, 1);
        passed &= run(instance, libvlc_playback_mode_loop, explicit_stop, 0, -1);
        passed &= run(instance, libvlc_playback_mode_loop, explicit_selection, 0, 1);
    }
    libvlc_release(instance);
    return passed ? 0 : 1;
}
