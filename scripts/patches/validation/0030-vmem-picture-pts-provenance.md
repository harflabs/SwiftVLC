# Patch 0030: vout-selected output-attempt PTS for result-bearing vmem

## Identity

- VLC base commit: `c833c4be000b426d73ff4324bec574065f00e3df`
- Required preceding SwiftVLC series: patches `0001` through `0029`
- Patch: `0030-vmem-picture-pts.patch`
- Patch SHA-256:
  `9542b6523151e6f719a171f1390dcfcdab910377feef8906330855d104dfc48a`
- The machine-local external build prefix is normalized below as
  `<external-build-root>`; the recorded replay-directory suffixes are unchanged.
- Clean series reconstruction used for the incremental diff:
  `<external-build-root>/Tmp/v6-patch-base.CsIHOl/vlc`
- Validated integration tree:
  `<external-build-root>/Tmp/current-native-series.C1XGlC/vlc`
- Clean manifest replay tree:
  `<external-build-root>/Tmp/v6-series-replay.t8D2lY/vlc`

The patch was generated only after applying the manifest-pinned `0001`–`0029`
series to a clean checkout. It therefore contains only the six native files
needed by version 6 and does not fold earlier recovery or strict-frame work
into a second patch.

## Contract

Version 6 is additive. It leaves
`swiftvlc_video_display_status_cb` and
`swiftvlc_libvlc_video_set_callbacks_atomic` byte-for-byte unchanged and adds:

```c
#define SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US INT64_MIN

typedef int (*swiftvlc_video_display_status_v2_cb)(
    void *opaque, void *picture, int64_t picture_pts_us);

int swiftvlc_libvlc_video_set_callbacks_atomic_v2(
    libvlc_media_player_t *mp,
    libvlc_video_lock_cb lock,
    libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display,
    swiftvlc_video_display_status_v2_cb display_status_v2,
    swiftvlc_video_format_ex_cb setup,
    libvlc_video_cleanup_cb cleanup,
    void *opaque);
```

The new setter publishes lock, unlock, legacy display, v6 result callback,
extended setup, cleanup and opaque as one retained immutable generation. It
accepts only a complete enable tuple or an all-NULL clear. Allocation failure
and partial input leave the preceding generation unchanged.

`vmem` captures `pic->date` during `Prepare`, before any callback. At this
point the picture has already passed VLC's decoder-output, late-picture,
filter/converter, and vmem lock/copy selection paths. The callback therefore
observes post-filter, vout-selected output attempts, not every decoded source
picture. A valid VLC tick is normalized with
`US_FROM_VLC_TICK(pic->date - VLC_TICK_0)`. The separate `date` argument is an
output scheduling deadline and is deliberately unused. A missing/invalid input
timestamp becomes `INT64_MIN`; it does not suppress pixel copy, unlock, display,
or submission-status handling. `Display` invokes the v6 result callback first,
then falls back to the frozen v4 result callback and finally the legacy void
callback.

## Validation pins

- `vmem-picture-pts-source-check.py`:
  `c3d38d12de458739e95bdacdedfcd5c233b9e41ce4bab922b5142c7cc9a3e8ad`
- `pip_extension_version.py`:
  `1582e0915d13a177fbe545099a1ed52696d1b60cfa5dbfd6a35a60943ccfcd36`
- `vmem-picture-pts-probe.c`:
  `65347de5f707e49e0d2208e4c8310f84026a518ff87730c0d17eabe5757d3bb7`
- `vmem-picture-pts-abi.cpp`:
  `b0c92e73eeb6bdf2e940a414d88f25322d99361939d6a77468891c933f1ca068`
- `vmem-configuration-race.c`:
  `35b2dfa2e5587b35f7b0966cb079cbaef83828ef33e97f77b9c0f426d7fde3d7`
- `strict-frame-step-source-check.py`:
  `c5345a4effcf441089c5b6cfeec003dfb3ad8a7eb127e60358e0d6025aa03ad6`
- `strict-frame-step-probe.c`:
  `bc9c69c9e86bb90cff568f0b32a0aef75b51330634bf5efeddd00b82a723aaa9`
- `validate-strict-frame-step.sh`:
  `eb37d715467ca7910674e2be33defca412df168394a13fe0619075188d6485d4`
- `validate-vmem-picture-pts.sh`:
  `5c83704621bb90827b77f5bba10d39f741d0c31cc698bae4be4ba04d3bcf3346`

The source checker includes negative mutations for scheduled-date
substitution, missing `VLC_TICK_0` normalization, zero-for-invalid coercion,
dropped v6 callback cloning, and a stale extension version. The race probe
publishes v4, v6 and clear generations concurrently with three acquiring
threads. It also forces allocation failure across v4-to-v6 and v6-to-v4
transitions and verifies that neither callback tuple tears.
The pre-existing strict-frame checker retains all of its frozen v4 checks. It
and the vmem checker now share one fail-closed source-composition resolver for
versions 4 through 10. The resolver requires complete, unique and contiguous
feature groups plus the exact literal version implementation; the vmem checker
then requires that the resolved version is at least 6. Patch 0033's audio
session leases are a separately provable same-version refinement introduced at
version 8 and retained unconditionally by versions 9 and 10.
Runtime probes receive one exact expected version owned by the ordered patch
manifest. They neither infer archive identity from the shipped headers nor
accept an open-ended version range.

The runtime PTS probe treats `play()` as asynchronous: an initial sampled
`Stopped` state is not terminal until playback activity is observed. It waits
for the complete evidence predicate (at least three output attempts and two
distinct PTS values), because VLC may legitimately redisplay the first
selected picture several times. A 20-second process watchdog bounds playback
and teardown. Stop must reach `Stopped`, and player release must quiesce every
vmem callback before the final aggregate is frozen. The strict-frame wrapper
accepts both a configured build root and VLC's Apple-driver `build/config.h`
layout.

The validator assets themselves have an exact inventory, SHA-256 and executable
mode manifest. Clean source replay, native build and release integrity all
verify that inventory before accepting the source or archive proof.

## Focused evidence (2026-09-01)

All compiler and temporary output was placed under
`<external-build-root>/Tmp`.

- Source/mutation gate: PASS.
- Public C11 and C++17 v4/v6 ABI syntax with `-Wall -Wextra -Werror`: PASS.
- Exact `lib/media_player.c` and `modules/video_output/vmem.c` syntax against
  the configured macOS arm64 VLC headers: PASS.
- Immutable-generation race syntax with `-Wall -Wextra -Werror`: PASS.
- Linked immutable-generation stress against the current host archive: PASS,
  latest run `A=48507 B=85489` (the scheduling-dependent counts are expected
  to vary; the v6 callback is intentionally invoked for both invalid and valid
  timestamp samples).
- `git diff --check` on the integrated native tree: PASS.
- Clean `0001`–`0030` manifest hash verification, patch replay, source/mutation
  validation, source syntax, ABI syntax and `git diff --check`: PASS.
- Linked public playback probe against the clean-build A intermediate
  version-8 macOS archive: PASS. Ten transition-aware diagnostic repetitions
  also passed; the tracked evidence-complete probe reported 29 callbacks and
  PTS progression from 0 to 80000 microseconds. The enclosing artifact remains
  unqualified until a fixed exact-head clean build reaches provenance.

## Scope boundary

This contract exposes presentation timestamps for post-filter, vout-selected
pictures that reach the synchronous vmem submission attempt. It is not a
lossless decoded-source oracle: VLC can drop pictures before this seam, and a
vmem lock/copy failure suppresses the callback. It does not expose frame
duration and it does not prove that submitted pixels were physically
presented. Release qualification must classify skipped/duplicate timestamps,
conserve every observed callback through an explicit Swift submission result,
and use the real-device visual-motion oracle. Neither callback count nor
timestamp delivery is a visible-pixel oracle.
