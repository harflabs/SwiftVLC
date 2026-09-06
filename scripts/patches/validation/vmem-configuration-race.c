/* Runtime stress for the exact immutable vmem configuration implementation. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <vlc_vmem_configuration.h>

enum { publish_iterations = 50000, acquire_iterations = 100000 };

struct generation_context
{
    uint64_t magic;
    atomic_uint setups;
    atomic_uint cleanups;
};

static struct generation_context generation_a = { .magic = 0xa11ce001 };
static struct generation_context generation_b = { .magic = 0xb11ce002 };
static atomic_uint failures;

#define DEFINE_GENERATION_CALLBACKS(suffix, expected_context)                 \
    static void *lock_##suffix(void *opaque, void **planes)                   \
    {                                                                          \
        if (opaque != &(expected_context))                                     \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
        planes[0] = opaque;                                                    \
        return opaque;                                                         \
    }                                                                          \
    static void unlock_##suffix(void *opaque, void *picture,                  \
                                void *const *planes)                           \
    {                                                                          \
        if (opaque != &(expected_context) || picture != opaque ||              \
            planes[0] != opaque)                                               \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
    }                                                                          \
    static void display_##suffix(void *opaque, void *picture)                 \
    {                                                                          \
        if (opaque != &(expected_context) || picture != opaque)                \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
    }                                                                          \
    static int status_##suffix(void *opaque, void *picture)                   \
    {                                                                          \
        if (opaque != &(expected_context) || picture != opaque)                \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
        return 0;                                                              \
    }                                                                          \
    static int status_v2_##suffix(void *opaque, void *picture,                \
                                  int64_t picture_pts_us)                      \
    {                                                                          \
        if (opaque != &(expected_context) || picture != opaque ||              \
            (picture_pts_us != SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US &&         \
             picture_pts_us != INT64_C(1234567)))                              \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
        return 0;                                                              \
    }                                                                          \
    static unsigned setup_##suffix(                                            \
        void **opaque, char *chroma,                                           \
        const swiftvlc_video_format_geometry_t *geometry,                      \
        unsigned *width, unsigned *height, unsigned *pitches,                 \
        unsigned *lines)                                                       \
    {                                                                          \
        if (*opaque != &(expected_context) || geometry->visible_width != 16 || \
            geometry->visible_height != 16)                                   \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
        memcpy(chroma, "RV32", 4);                                            \
        *width = *height = 16;                                                 \
        pitches[0] = 64;                                                       \
        lines[0] = 16;                                                         \
        atomic_fetch_add_explicit(&(expected_context).setups, 1,               \
                                  memory_order_relaxed);                       \
        return 1;                                                              \
    }                                                                          \
    static void cleanup_##suffix(void *opaque)                                \
    {                                                                          \
        if (opaque != &(expected_context))                                     \
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);     \
        atomic_fetch_add_explicit(&(expected_context).cleanups, 1,             \
                                  memory_order_relaxed);                       \
    }

DEFINE_GENERATION_CALLBACKS(a, generation_a)
DEFINE_GENERATION_CALLBACKS(b, generation_b)

struct stress_context
{
    swiftvlc_vmem_configuration_registry *registry;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned arrivals;
    unsigned phase;
};

enum { a_published, a_acquired, b_published, b_acquired,
       disabled_published, snapshots_exercised };

/* Portable four-party barrier: macOS does not provide pthread_barrier_t. */
static void rendezvous(struct stress_context *stress, unsigned phase)
{
    pthread_mutex_lock(&stress->lock);
    if (stress->phase != phase)
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    if (++stress->arrivals == 4)
    {
        stress->arrivals = 0;
        ++stress->phase;
        pthread_cond_broadcast(&stress->changed);
    }
    else
        while (stress->phase == phase)
            pthread_cond_wait(&stress->changed, &stress->lock);
    pthread_mutex_unlock(&stress->lock);
}

static bool publish_generation(struct stress_context *stress, bool a)
{
    if (a)
        return swiftvlc_vmem_configuration_registry_PublishComplete(
            stress->registry, lock_a, unlock_a, display_a, status_a,
            setup_a, cleanup_a, &generation_a);
    return swiftvlc_vmem_configuration_registry_PublishCompleteV2(
        stress->registry, lock_b, unlock_b, display_b, status_v2_b,
        setup_b, cleanup_b, &generation_b);
}

static void *publisher(void *opaque)
{
    struct stress_context *stress = opaque;
    /* Retire each generation while every opener holds it. The free-running
     * stress below may otherwise finish publishing before any opener runs. */
    if (!publish_generation(stress, true))
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    rendezvous(stress, a_published);
    rendezvous(stress, a_acquired);
    if (!publish_generation(stress, false))
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    rendezvous(stress, b_published);
    rendezvous(stress, b_acquired);
    if (!swiftvlc_vmem_configuration_registry_PublishCompleteV2(
            stress->registry, NULL, NULL, NULL, NULL, NULL, NULL, NULL))
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    rendezvous(stress, disabled_published);
    rendezvous(stress, snapshots_exercised);
    for (unsigned iteration = 0; iteration < publish_iterations; ++iteration)
    {
        bool ok;
        switch (iteration % 3)
        {
            case 0:
                ok = publish_generation(stress, true);
                break;
            case 1:
                ok = publish_generation(stress, false);
                break;
            default:
                ok = swiftvlc_vmem_configuration_registry_PublishCompleteV2(
                    stress->registry, NULL, NULL, NULL, NULL, NULL, NULL,
                    NULL);
                break;
        }
        if (!ok)
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    }
    return NULL;
}

static void exercise_snapshot(
    const swiftvlc_vmem_configuration *configuration)
{
    if (configuration->lock == NULL)
    {
        if (configuration->unlock != NULL || configuration->display != NULL ||
            configuration->display_status != NULL ||
            configuration->display_status_v2 != NULL ||
            configuration->setup != NULL || configuration->setup_ex != NULL ||
            configuration->cleanup != NULL || configuration->opaque != NULL)
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
        return;
    }

    const bool a = configuration->opaque == &generation_a;
    const bool b = configuration->opaque == &generation_b;
    if ((!a && !b) || configuration->setup != NULL ||
        configuration->lock != (a ? lock_a : lock_b) ||
        configuration->unlock != (a ? unlock_a : unlock_b) ||
        configuration->display != (a ? display_a : display_b) ||
        configuration->display_status != (a ? status_a : NULL) ||
        configuration->display_status_v2 != (b ? status_v2_b : NULL) ||
        configuration->setup_ex != (a ? setup_a : setup_b) ||
        configuration->cleanup != (a ? cleanup_a : cleanup_b))
    {
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
        return;
    }

    void *setup_opaque = configuration->opaque;
    char chroma[5] = { 0 };
    const swiftvlc_video_format_geometry_t geometry = {
        .coded_width = 16, .coded_height = 16,
        .visible_width = 16, .visible_height = 16,
        .sar_num = 1, .sar_den = 1,
    };
    unsigned width = 16, height = 16, pitches[4] = { 0 }, lines[4] = { 0 };
    if (configuration->setup_ex(&setup_opaque, chroma, &geometry, &width,
                                &height, pitches, lines) != 1)
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    void *planes[1] = { NULL };
    void *picture = configuration->lock(setup_opaque, planes);
    configuration->unlock(setup_opaque, picture, planes);
    configuration->display(setup_opaque, picture);
    if (a)
    {
        if (configuration->display_status(setup_opaque, picture) != 0)
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    }
    else
    {
        if (configuration->display_status_v2(
                setup_opaque, picture,
                SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US) != 0 ||
            configuration->display_status_v2(
                setup_opaque, picture, INT64_C(1234567)) != 0)
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    }
    configuration->cleanup(setup_opaque);
}

static void *opener(void *opaque)
{
    struct stress_context *stress = opaque;
    rendezvous(stress, a_published);
    const swiftvlc_vmem_configuration *a =
        swiftvlc_vmem_configuration_registry_Acquire(stress->registry);
    rendezvous(stress, a_acquired);
    rendezvous(stress, b_published);
    const swiftvlc_vmem_configuration *b =
        swiftvlc_vmem_configuration_registry_Acquire(stress->registry);
    rendezvous(stress, b_acquired);
    rendezvous(stress, disabled_published);
    const swiftvlc_vmem_configuration *disabled =
        swiftvlc_vmem_configuration_registry_Acquire(stress->registry);
    if (a == NULL || a->opaque != &generation_a ||
        b == NULL || b->opaque != &generation_b ||
        disabled == NULL || disabled->lock != NULL)
        atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
    if (a != NULL)
        exercise_snapshot(a);
    if (b != NULL)
        exercise_snapshot(b);
    if (disabled != NULL)
        exercise_snapshot(disabled);
    swiftvlc_vmem_configuration_Release(a);
    swiftvlc_vmem_configuration_Release(b);
    swiftvlc_vmem_configuration_Release(disabled);
    rendezvous(stress, snapshots_exercised);
    for (unsigned iteration = 0; iteration < acquire_iterations; ++iteration)
    {
        const swiftvlc_vmem_configuration *configuration =
            swiftvlc_vmem_configuration_registry_Acquire(stress->registry);
        if (configuration == NULL)
        {
            atomic_fetch_add_explicit(&failures, 1, memory_order_relaxed);
            continue;
        }
        exercise_snapshot(configuration);
        swiftvlc_vmem_configuration_Release(configuration);
    }
    return NULL;
}

int main(void)
{
    /* Compile and invoke both callback signatures independently so the v4
     * typedef cannot be silently rewritten into the timestamp-bearing ABI. */
    if (status_b(&generation_b, &generation_b) != 0 ||
        status_v2_a(&generation_a, &generation_a,
                    SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US) != 0)
        return 1;

    struct stress_context stress = {
        .registry = swiftvlc_vmem_configuration_registry_New(),
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    if (stress.registry == NULL)
        return 2;

    /* The exact publisher allocates before taking ownership of the old
     * generation. A forced allocation failure must leave A as the next Open
     * snapshot, never a partial B tuple. */
    if (!publish_generation(&stress, true))
        return 2;
    swiftvlc_vmem_configuration_registry_ForceAllocationFailure(
        stress.registry, true);
    bool failed_publish = publish_generation(&stress, false);
    swiftvlc_vmem_configuration_registry_ForceAllocationFailure(
        stress.registry, false);
    const swiftvlc_vmem_configuration *preserved =
        swiftvlc_vmem_configuration_registry_Acquire(stress.registry);
    bool preserved_a = preserved != NULL
        && preserved->lock == lock_a
        && preserved->unlock == unlock_a
        && preserved->display == display_a
        && preserved->display_status == status_a
        && preserved->display_status_v2 == NULL
        && preserved->setup_ex == setup_a
        && preserved->cleanup == cleanup_a
        && preserved->opaque == &generation_a;
    swiftvlc_vmem_configuration_Release(preserved);
    if (failed_publish || !preserved_a)
        return 1;

    /* Prove the inverse transition too: a failed v4 publication must retain
     * the complete v6 tuple, including its timestamp-bearing callback. */
    if (!publish_generation(&stress, false))
        return 2;
    swiftvlc_vmem_configuration_registry_ForceAllocationFailure(
        stress.registry, true);
    failed_publish = publish_generation(&stress, true);
    swiftvlc_vmem_configuration_registry_ForceAllocationFailure(
        stress.registry, false);
    preserved = swiftvlc_vmem_configuration_registry_Acquire(stress.registry);
    bool preserved_b = preserved != NULL
        && preserved->lock == lock_b
        && preserved->unlock == unlock_b
        && preserved->display == display_b
        && preserved->display_status == NULL
        && preserved->display_status_v2 == status_v2_b
        && preserved->setup_ex == setup_b
        && preserved->cleanup == cleanup_b
        && preserved->opaque == &generation_b;
    swiftvlc_vmem_configuration_Release(preserved);
    if (failed_publish || !preserved_b)
        return 1;

    pthread_t publish_thread;
    pthread_t open_threads[3];
    if (pthread_create(&publish_thread, NULL, publisher, &stress) != 0)
        return 2;
    for (size_t index = 0; index < 3; ++index)
        if (pthread_create(&open_threads[index], NULL, opener, &stress) != 0)
            return 2;

    pthread_join(publish_thread, NULL);
    for (size_t index = 0; index < 3; ++index)
        pthread_join(open_threads[index], NULL);
    swiftvlc_vmem_configuration_registry_Delete(stress.registry);
    pthread_cond_destroy(&stress.changed);
    pthread_mutex_destroy(&stress.lock);

    const unsigned a_setups = atomic_load_explicit(&generation_a.setups,
                                                    memory_order_relaxed);
    const unsigned b_setups = atomic_load_explicit(&generation_b.setups,
                                                    memory_order_relaxed);
    const bool balanced = a_setups != 0 && b_setups != 0
        && a_setups == atomic_load_explicit(&generation_a.cleanups,
                                            memory_order_relaxed)
        && b_setups == atomic_load_explicit(&generation_b.cleanups,
                                            memory_order_relaxed);
    if (!balanced || atomic_load_explicit(&failures,
                                          memory_order_relaxed) != 0)
    {
        fprintf(stderr,
                "vmem immutable-generation race failed: A=%u B=%u errors=%u\n",
                a_setups, b_setups,
                atomic_load_explicit(&failures, memory_order_relaxed));
        return 1;
    }

    printf("PASS vmem immutable generations A=%u B=%u\n", a_setups,
           b_setups);
    return 0;
}
