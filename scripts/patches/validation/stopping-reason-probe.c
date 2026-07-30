/* Runtime proof for patch 0015 (expose the media stopping reason).
 *
 * 0015 is the one patch in this directory that is not a verbatim upstream
 * backport, so "it compiles and the static_assert holds" is a weaker claim
 * here than elsewhere: it shows the enums line up, not that the reason
 * actually reaches the event with the right value. This checks the latter.
 *
 * Plays a short file to its natural end and records the reason, then plays it
 * again and stops it explicitly. Expects eos (1) then user (2). Without the
 * patch the `reason` field does not exist and this fails to compile, which is
 * itself a useful signal.
 *
 * Not wired into CI: it needs a libvlc built from a patched tree, which CI
 * does not produce. Run it against a local engine build after changing 0015.
 *
 * Compile against Sources/CLibVLC/include, NOT "$V/include". Those are the
 * headers the xcframework ships and SwiftPM compiles against; the patched
 * source tree's headers are not shipped anywhere. An earlier run used
 * "$V/include" and passed while every shipped header still declared a
 * `media_player_media_stopping` with no `reason` field, so the value reached
 * the library and no consumer could read it. Using the vendored path makes
 * this probe fail to compile in that situation, which is the point.
 *
 *   V=scripts/.build-libvlc/vlc
 *   clang -o /tmp/stopping-reason-probe \
 *     scripts/patches/validation/stopping-reason-probe.c \
 *     -I Sources/CLibVLC/include -L "$V/build-asan-native/lib/.libs" -lvlc
 *   VLC_PLUGIN_PATH="$V/build-asan-native/modules" \
 *   DYLD_LIBRARY_PATH="$V/build-asan-native/src/.libs:$V/build-asan-native/lib/.libs" \
 *     /tmp/stopping-reason-probe <some-short-media-file>
 *
 * Last run against the pin with patches 0001-0015 applied:
 *   PASS eos    reason=eos  (1)
 *   PASS user   reason=user (2)
 */
#include <vlc/vlc.h>
#include <stdio.h>
#include <time.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int seen = 0;
static libvlc_stopping_reason_t last_reason;

static void on_event(const libvlc_event_t *ev, void *data)
{
    (void) data;
    if (ev->type != libvlc_MediaPlayerMediaStopping)
        return;
    pthread_mutex_lock(&lock);
    last_reason = ev->u.media_player_media_stopping.reason;
    seen = 1;
    pthread_cond_signal(&cond);
    pthread_mutex_unlock(&lock);
}

static const char *name(libvlc_stopping_reason_t r)
{
    switch (r) {
    case libvlc_stopping_reason_error: return "error";
    case libvlc_stopping_reason_eos:   return "eos";
    case libvlc_stopping_reason_user:  return "user";
    }
    return "?";
}

static int run(libvlc_instance_t *vlc, const char *path, int stop_early,
               const char *expected)
{
    libvlc_media_t *m = libvlc_media_new_path(path);
    if (!m) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    libvlc_media_player_t *mp = libvlc_media_player_new_from_media(vlc, m);
    if (!mp) {
        fprintf(stderr, "cannot create player\n");
        libvlc_media_release(m);
        return 1;
    }

    libvlc_event_manager_t *em = libvlc_media_player_event_manager(mp);
    libvlc_event_attach(em, libvlc_MediaPlayerMediaStopping, on_event, NULL);

    pthread_mutex_lock(&lock); seen = 0; pthread_mutex_unlock(&lock);
    libvlc_media_player_play(mp);

    if (stop_early) {
        usleep(300 * 1000);
        libvlc_media_player_stop_async(mp);
    }

    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 15;
    pthread_mutex_lock(&lock);
    while (!seen && pthread_cond_timedwait(&cond, &lock, &ts) == 0) {}
    int got = seen;
    libvlc_stopping_reason_t r = last_reason;
    pthread_mutex_unlock(&lock);

    libvlc_media_player_release(mp);
    libvlc_media_release(m);

    if (!got) { printf("FAIL %-18s no MediaStopping event\n", expected); return 1; }
    int ok = strcmp(name(r), expected) == 0;
    printf("%s %-18s reason=%s (%d)\n", ok ? "PASS" : "FAIL", expected, name(r), (int) r);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <media>\n", argv[0]); return 2; }
    const char *args[] = { "--no-audio", "--vout=dummy", "--aout=dummy" };
    libvlc_instance_t *vlc = libvlc_new(3, args);
    if (!vlc) { fprintf(stderr, "libvlc_new failed\n"); return 2; }

    int rc = 0;
    rc |= run(vlc, argv[1], 0, "eos");
    rc |= run(vlc, argv[1], 1, "user");

    libvlc_release(vlc);
    printf(rc ? "\nRESULT: FAILED\n" : "\nRESULT: PASSED\n");
    return rc;
}
