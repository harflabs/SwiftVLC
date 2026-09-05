/* State regression for patch 0043's ordered semantic-text snapshot.
 *
 * This intentionally needs no libVLC build: it verifies that only active
 * semantic regions enter the snapshot, WebVTT placement stays attached to its
 * region, and channel removal does not consult bitmap or future entries.
 *
 *   cc -std=c11 -Wall -Wextra -Werror \
 *     scripts/patches/validation/subtitle-text-snapshot.c \
 *     -o /tmp/subtitle-text-snapshot && /tmp/subtitle-text-snapshot
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct queued_region
{
    size_t channel_id;
    const char *text;
    bool active;
    bool semantic;
    bool is_webvtt;
    float horizontal_position;
    float vertical_position;
};

struct snapshot_region
{
    size_t channel_id;
    const char *text;
    bool is_webvtt;
    float horizontal_position;
    float vertical_position;
};

struct snapshot
{
    struct snapshot_region regions[8];
    size_t count;
};

static void Fail(const char *message)
{
    fprintf(stderr, "subtitle text snapshot validation failed: %s\n", message);
    exit(EXIT_FAILURE);
}

static void CaptureActiveSemanticRegions(
    struct snapshot *snapshot, const struct queued_region *regions,
    size_t count)
{
    snapshot->count = 0;
    for (size_t i = 0; i < count; ++i)
    {
        if (!regions[i].active || !regions[i].semantic)
            continue;
        if (snapshot->count == 8)
            Fail("test snapshot capacity exceeded");
        snapshot->regions[snapshot->count++] = (struct snapshot_region) {
            .channel_id = regions[i].channel_id,
            .text = regions[i].text,
            .is_webvtt = regions[i].is_webvtt,
            .horizontal_position = regions[i].horizontal_position,
            .vertical_position = regions[i].vertical_position,
        };
    }
}

static void RemoveChannel(struct snapshot *snapshot, size_t channel_id)
{
    size_t output = 0;
    for (size_t i = 0; i < snapshot->count; ++i)
    {
        if (snapshot->regions[i].channel_id != channel_id)
            snapshot->regions[output++] = snapshot->regions[i];
    }
    snapshot->count = output;
}

static void ExpectText(const struct snapshot *snapshot, const char *expected,
                       const char *message)
{
    char actual[128] = "";
    size_t length = 0;
    for (size_t i = 0; i < snapshot->count; ++i)
    {
        int written = snprintf(actual + length, sizeof(actual) - length,
                               "%s%s", i == 0 ? "" : "\n",
                               snapshot->regions[i].text);
        if (written < 0 || (size_t) written >= sizeof(actual) - length)
            Fail("test aggregate capacity exceeded");
        length += (size_t) written;
    }

    if (strcmp(actual, expected) != 0)
        Fail(message);
}

static void ExpectWebVTTPlacement(const struct snapshot *snapshot, size_t index,
                                  float horizontal, float vertical,
                                  const char *message)
{
    if (index >= snapshot->count
     || !snapshot->regions[index].is_webvtt
     || snapshot->regions[index].horizontal_position != horizontal
     || snapshot->regions[index].vertical_position != vertical)
        Fail(message);
}

int main(void)
{
    const struct queued_region regions[] = {
        { .channel_id = 10, .text = "primary", .active = true,
          .semantic = true },
        { .channel_id = 10, .text = "continued", .active = true,
          .semantic = true, .is_webvtt = true,
          .horizontal_position = 0.15f, .vertical_position = 0.20f },
        { .channel_id = 11, .text = "secondary", .active = true,
          .semantic = true, .is_webvtt = true,
          .horizontal_position = 0.80f, .vertical_position = 0.30f },
        { .channel_id = 12, .text = "future", .active = false,
          .semantic = true },
        { .channel_id = 13, .text = NULL, .active = true,
          .semantic = false },
    };

    struct snapshot snapshot;
    CaptureActiveSemanticRegions(&snapshot, regions,
                                 sizeof(regions) / sizeof(regions[0]));
    ExpectText(&snapshot, "primary\ncontinued\nsecondary",
               "capture included bitmap or future regions");
    if (snapshot.regions[0].is_webvtt)
        Fail("automatic region acquired WebVTT provenance");
    ExpectWebVTTPlacement(&snapshot, 1, 0.15f, 0.20f,
                          "first WebVTT placement was not preserved");
    ExpectWebVTTPlacement(&snapshot, 2, 0.80f, 0.30f,
                          "second WebVTT placement was not preserved");

    RemoveChannel(&snapshot, 13);
    ExpectText(&snapshot, "primary\ncontinued\nsecondary",
               "clearing a bitmap channel changed semantic text");

    RemoveChannel(&snapshot, 10);
    ExpectText(&snapshot, "secondary",
               "clearing primary text did not preserve active secondary text");

    RemoveChannel(&snapshot, 11);
    ExpectText(&snapshot, "",
               "bitmap or future entries prevented the final empty snapshot");

    puts("subtitle text snapshot validation passed");
    return EXIT_SUCCESS;
}
