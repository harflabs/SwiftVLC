# v0.10.0 execution progress

Working log for the PLAN.md execution on `v0.10.0-dev`. Per-item status, test
evidence, and deviations. Statuses: DONE / IN-PROGRESS / PENDING /
PENDING-DEVICE (needs hardware the session does not have).

Baseline verified at start: `CI=true swift test --no-parallel` → 1397 tests,
109 suites, all green in ~35 s (Swift 6.3.2, Xcode 26.5, macOS host).

Local-dev note: `./scripts/setup-dev.sh --skip-download` was run once at
session start — Package.swift points at `Vendor/libvlc.xcframework` and the
Showcase project at the local package checkout. CI scripts rewrite both forms,
so this state is committed as-is on the dev branch.

## M0 — Test & CI hardening — DONE

| Item | Status | Evidence / notes |
|---|---|---|
| F036 guard-poll → `try #require` | DONE | 34 single-line sites converted across 8 files + 11 multi-line silent guards converted across the EventBridge Deep/Final/Stress suites. 3 guards intentionally kept: their else-blocks carry real `#expect` fallback assertions (graceful degradation, not silent bailouts). Red-test verified: with `playerEventCallback` delivery disabled, EventBridgeTests fails 11/14 (the 3 non-failing tests don't assert delivery); reverted and green. |
| F036 fallout — dead tests revived | DONE | The conversion exposed 16 tests that could never reach their awaited condition and had silently passed for their whole life: 13 playback-driving tests built on `TestInstance.shared` (no outputs — `.playing` unreachable) → switched to `TestInstance.makePlayback()`; 2 PiPController playback tests additionally gained the `canPlayMedia` gate; mute/volume event tests can never see `.muted`/`.volumeChanged` under the dummy aout (it swallows the reports) → new `TestInstance.makeRealAudioPlayback()` (real aout, dummy vout, local-only). One structurally-impossible wait (`.idle` after stop — libVLC 4 reports `.stopped`) rewritten to await `.stopped`. One test consumer that broke on `.playing` while the test then awaited a recorded `.stopped` fixed to record through stop. |
| F041 playback-free teardown races | DONE | New `PlaybackFreeTeardownRaceTests` (4 tests: bridge churn across deinit, repeated native-handle swap via `setDrawable→stop→prepareDrawableForPlayback` with a live stream surviving reattach, offloaded-deinit weak-probe drain, deinit mid-consumption). Runs under CI=true. TSan + ASan green (see below). |
| F074 dead `MemoryTests` token | DONE | Removed from sanitize.yml filter; comment documents the playback-gap rationale. |
| P1.13 unit half — tvOS simulator test job | DONE | `tvos-test` job in test.yml. Critical detail: `TEST_RUNNER_CI=true` must be in the step `env:` (xcodebuild forwards TEST_RUNNER_-prefixed *environment* variables; as a CLI arg it is a build setting and never reaches the test process — first local run proved this). Local run green: `TEST_RUNNER_CI=true xcodebuild test -scheme SwiftVLC -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'`. |
| P1.13 fallout — real tvOS-slice fixes | DONE | Two genuine tvOS behavioral differences surfaced and encoded: (1) `canIssueNativePause` is `true` on a fresh tvOS player (negative uninitialized-volume sentinel ⇒ pause is safe), test asserts per-platform; (2) `RendererDiscoverer.start()` throws on tvOS (slice ships no renderer-discovery backends though the service is enumerable) — stress test treats unstartable discovery as platform no-op. |
| P2.19 CI half — archive manifests | DONE | `scripts/check-libvlc-manifest.sh` + per-slice manifests in `scripts/libvlc-manifests/` (per-arch member lists via `lipo -thin` — `ar t` rejects fat archives, so manifests are strictly stronger than the planned recipe), `--write` regeneration mode, all 8 slices PASS locally; `.github/workflows/vendor-manifest.yml`. |
| §3.14 DynamicHost fixture | DONE | `Fixtures/DynamicHost`: **two** packages (MediaCoreKit: dynamic `MediaCore` product owning SwiftVLC; MediaKit: static FeatureA/B over the MediaCore *product*) + iOS/tvOS host apps + `verify.sh`. Single-package shape is unbuildable in Xcode 26 (recorded in the docc page). verify.sh PASS on both platforms: exactly one image defines `_libvlc_new` (MediaCore.framework); `--launch` PASS (single shared VLCInstance, zero duplicate-class warnings). `ENABLE_DEBUG_DYLIB=NO` required. CI: `.github/workflows/fixtures.yml`. Docc page `IntegrationTopology.md` ships, claims match observed results. SwiftVLC's root product stays automatic-type (correct for single-module apps; fixture proves the layered contract). |

M0 verification evidence:
- Strict concurrency build: `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` → 0 warnings.
- `CI=true swift test --no-parallel` → green (1401 tests / 110 suites).
- `swift test --no-parallel` (playback) → green ×2 consecutive (~150 s each).
- TSan: `CI=true swift test --sanitize=thread --no-parallel --filter "RaceTests|StressTests|MemoryAndRetainTests|MemoryPressureTests|LifecycleStressTests"` → 88 tests green.
- ASan: filter `"Memory|Broadcaster|EventBridge"` → 110 tests green.
- tvOS simulator suite → green after the two tvOS fixes (run id in session log).

Known flake watch: one full-suite run crashed (SIGSEGV-style abrupt end) inside
`MediaListPlayerTests."State during playback"`; not reproducible (3× isolated,
2× full-suite green afterwards). Matches the documented cross-test libVLC
state-bleed class in TestInstance.swift. Watching on every milestone run.

## Rebase onto moved main (2026-06-10, user-requested)

origin/main moved past v0.9.1 by three commits; `v0.10.0-dev` was rebased onto
it cleanly (no conflicts), local `main` fast-forwarded. Upstream deltas that
affect the plan:

- `c14a508` (#54) lands **P0.6's spike-independent half** on main: public
  `PiPController.onRestoreUserInterface` (completion-handler shape, not the
  async-closure shape PLAN sketched) plus the sample-buffer-path delegate
  `restoreUserInterfaceForPictureInPictureStop…` implementation, with tests.
  M4 builds on the landed shape; remaining P0.6 scope = native-path
  interception (spike-gated), P1.12 stream, F061. The PLAN.md statement
  "grep -rn restoreUserInterface Sources/ = zero hits" is now stale.
- `51ace97` reworked `10-Diagnostics-Events.swift` / `MultiConsumer` — F023
  (M1) applies to the updated file.
- `d800654` chapter-title guards — no overlap with v0.10.0 surfaces.

Post-rebase evidence: strict build 0 warnings; CI suite green (1405 tests);
local playback suite green (one unidentified single-issue run did not
reproduce — logged under flake watch).

## M5a — Harness skeleton + screens (a)/(c) — DONE

Showcase iOS "Validation Harness" section: `HarnessStreams` config loader
(bundled gitignored `streams.local.json` → Documents fallback; example file
committed), `HarnessResultStore` (persisted PASS/FAIL/observation + JSON
export), `HarnessHome` with the full (a)–(g)+smoke matrix (config-gated rows),
screen (a) same-Player zap-under-PiP with timestamped event log, screen (c)
restore/X baseline with `@_spi(ValidationHarness)`
`PiPController.nativeValidationProbe` (window-controller class, AV controller
presence, delegate class + 5-selector respondsToSelector table). Showcase iOS
scheme builds for the simulator; package strict build stays at 0 warnings.
Screens' PASS/FAIL outcomes are device-gated (PiP is simulator-blind) —
recorded under PENDING-DEVICE at the end.

## M1 — Event delivery (P2.14 + F001/F004/F009/F037/F023) — DONE

| Item | Status | Evidence / notes |
|---|---|---|
| P2.14 public API | DONE | `EventBufferingPolicy` (`.newest(Int)` clamped ≥1, `.unbounded`), `Player.events(policy:filter:)` (parameterless `events` kept as sugar), `Player.stateTransitions` (lossless, lifecycle-only, pump-task bridged). Docs carry the swapped-handle non-delivery limitation and the blocking-filter/teardown deadlock caveat. |
| Filter hoist | DONE | `Broadcaster.broadcast` snapshots subscribers under the Mutex, evaluates filters + yields outside; F012 single-subscriber fast path folded in (the hoist rewrote the fan-out loop, per the conditional-rider rule). Re-entrancy tests (filter calling `isEmpty`/`subscribe`/`player.events`) green. |
| Internal consumer | DONE | Sourced subscription `.unbounded`; pinning test broadcasts a `lengthChanged` then 128-event firehose through the bridge before the consumer runs and requires the mirror to surface it (red-green verified by removing the policy argument). |
| F001 (#34) | DONE→SUPERSEDED | The single-critical-section fix landed, then the adversarial review proved the whole phase machine still double-fires under schedule-order inversion (pre-existing). Replaced `lifecyclePending` with an `attached` flag + convergent `runReconciliation()` loop on the serial queue; reconciliation passes are scheduled while holding the state lock so FIFO order matches transition order. Churn test green 10×10 iterations (pre-rewrite flake rate was ~13%). |
| F004 (#36) | DONE | `BroadcasterBox.value` weak; weak-probe test on a non-shared instance red-green verified (strong box → leak detected → weak → green). |
| F009 | DONE | Per-broadcaster `isEmpty` gating in the bridge context; sourced broadcast ordered BEFORE the public one so user filters can never delay internal state mirroring (review finding). |
| F037 (#46) | DONE | Same-stream-across-swap test; red-green verified by disabling `eventBridge.reattach(to:)`. |
| F023 | DONE | All three platform diagnostics case studies subscribe before `play()` with `.unbounded` + subscription-time firehose filter; iOS/macOS/tvOS showcase schemes build. |

Adversarial review (3 lenses → 14 agents, 8 confirmed findings) drove: the
reconciliation rewrite, broadcast ordering, `.newest` clamping, honest
internal-consumer doc, the internal-consumer pinning test, headless
policy+filter and stateTransitions tests (via a new `EventBridge.
_broadcastForTesting` hook), and the filter/teardown doc caveat. All
confirmed findings fixed or pinned; none deferred.

## M2 — Stop/teardown cluster (ONE unit) — DONE

| Item | Status | Evidence / notes |
|---|---|---|
| P1.10 `stopAndWait()` / `shutdown()` | DONE | `Player+Teardown.swift`. `stopAndWait` subscribes an unbounded sourced stream before issuing the stop, double-checks the native terminal state around the subscription (closes the missed-event stall), reconciles the observable mirror on return (red-test-discovered gap), 10 s defensive ceiling. `shutdown` shares `teardownNativePlayer` with `deinit` (the choreography exists once), detaches an attached `MediaListPlayer`, clears intent/pause state, awaits the offloaded teardown via checked continuation, and swaps in an inert handle so post-shutdown calls are safe no-ops. |
| P0.2 `.endReached` / `didReachEnd` | DONE | `PlaybackEndCoordinator` consulted by the C callback after broadcasting `.stopped`; synthesis suppressed by library stop, error latch, or list-player attachment; ordering (`.stopped` then `.endReached`, same source) asserted in tests. 8-test playback matrix green ×3 locally; full CI-eligible coordinator decision-table unit suite added. |
| P0.3 `recast(to:)` | DONE (device leg PENDING-DEVICE) | Rides the lazy replacement path; restores prior renderer/flags only when the throw pre-dates the handle commit; awaits new-session `.playing` then seekability before the time restore; never awaits the old handle's stop (§4 rule 7). Real-sink hand-off is harness matrix (d′), device-only. |
| F003 carry-over | DONE | `carryOverPerPlayerState`: marquee ints + `_marqueeText` shadow (never the live old-handle text — may hold a transient cache-bust value), logo ints + `_logoFile` shadow, adjustments, stereo/mix, `_teletextPage`/`_deinterlaceState`/`_audioOutputModule`/`_audioOutputDevice`/`_viewpoint` shadows. Deliberate resets documented: A-B loop, track/chapter/title, DVB program selection. Deinterlace carry-over has native read-back parity coverage (red-green verified); teletext/audio-routing/viewpoint native read-back is impossible headless — shadow-only tests say so explicitly. |
| F005 list-player rebind | DONE | `rebindMediaPlayerHandle()` called from the swap; attach/detach manages end-synthesis suppression. |
| F022 Logo live pointer | DONE | Logo mirrors Marquee (player held, pointer computed). |
| F024 showcase stops | DONE | All three platform playlist case studies stop the list player and drain the Player via `Task { await player.stopAndWait() }`; three schemes build. |
| F034 `setRate` internal | DONE | `setPlaybackRate(_:)` is the single public mutator. |
| F043/F044 weak-probe drawable release | DONE | Both orderings (swap-retained drain ≤5 s; plain detach immediate). |
| F052 cleanup probe rewrite | DONE | Probe measures `await shutdown()` completion (<2 s asserted); concurrent-queue hack gone. |

Adversarial review (3 lenses → 25 agents, 22 confirmed findings ≈ 11 unique)
drove the second wave of fixes:
- Phantom-`.endReached` classes closed: list-player detach mid-playback now
  marks the deferred native stop before lifting suppression; list-player
  `deinit` lifts suppression (weak refs read nil during deinit — ownership
  guard accepts the nil arm); `didReachEnd` latches only when playback
  intent is inactive (consumer-outpaces-mirror race).
- The review's third phantom claim (bare `load()` while playing) was
  implemented and then **reverted with red-green proof**: against the pinned
  libVLC 4 binary, `set_media` on a started handle replaces seamlessly
  (`mediaStopping` → `mediaChanged`, **no `Stopped`**), so the proposed mark
  swallowed the next genuine end instead of fixing anything. The seamless
  semantics are documented at the `load()` site and pinned by a regression
  test. (The review's source citation — vlc_player.h prose — disagrees with
  the shipped binary; the binary wins.)
- `stop()` TOCTOU (consume-before-mark, microsecond window, self-healing at
  one suppressed end) documented at the site rather than closed — a fix
  needs a session generation token for no practical gain.
- shutdown intent/pause-state reset; recast restore-coherence + honest
  Throws docs; program-selection added to the deliberate-reset docs.

PLAN §3.3 acceptance deviation: "all seven tests green on macOS and tvOS-sim
CI" is structurally unmeetable — both CI jobs set CI/TEST_RUNNER_CI
deliberately (GHA macOS runners crash in libVLC's hardware-accel probe;
documented in TestInstance.swift). Compensation: the matrix runs green
locally (macOS, 3×), a one-off local tvOS-simulator run without the CI gate
executes it on tvOS (result below), and the coordinator's decision logic has
ungated CI unit coverage.

tvOS-simulator playback run (one-off, no CI gate, Apple TV 4K 3rd gen sim):
the complete end-reached matrix — all 8 §3.3 tests plus the 3 review-driven
regressions — PASSED on tvOS. Two unrelated playback tests fail on the tvOS
simulator only (`EventBridgeTests."Volume changed event"` — the tvOS sim's
real aout does not report volume events; `VideoSurfaceRaceTests."serial
multi-surface attach ordering"`) — environmental differences in suites that
no CI configuration executes on tvOS by design; recorded, not gating.

M2 verification evidence: strict build 0 warnings; CI suite green (1457
tests / 116 suites); local playback suite green ×2 (~140 s); TSan green;
ASan green; swiftlint --strict and swiftformat --lint clean repo-wide
(Player.swift split into Player+Teardown.swift / Player+Drawable.swift and
the PiP probe into PiPController+Validation.swift to satisfy file_length).

## M3 — Seek & playback info — DONE

| Item | Status | Evidence / notes |
|---|---|---|
| P0.1 lenient seek | DONE (harness leg PENDING-DEVICE) | `Player+Seek.swift` (seek family relocated): `seek(toPosition:fast:)` / `jump(by:)` return `Bool`, never throw, never derive targets from `currentTime`/`duration`. Pinned-binary discovery: the C entry points return success even with no media, so a Swift-side session gate fronts them — `isPlaybackRequestedActive` (covers the just-issued-`play()` turn) else a native-state read; the mirror-state version of the gate was a review-confirmed bug (play-then-seek no-op'd) and was fixed with same-turn tests. Timeshift `set_position` acceptance is harness matrix (f), device-only. |
| P3.1 fast | DONE | `fast:` on both strict call sites (`seek(to:fast:)`, `seek(by:fast:)`). Discriminating test on a new committed sparse-keyframe fixture (`sparse.mp4`, I-frames at 0 s/10 s): precise lands ≈9 s, fast snaps to the keyframe (red-green verified by hardcoding the flag off). |
| F017 position publication | DONE | All strict + lenient paths publish derived `position` (and `currentTime`) when computable, including paused `jump(by:)` (review-driven). |
| P0.4 videoSize/hasVideoOutput | DONE | `Player+VideoInfo.swift`. Pinned-binary discoveries: `has_vout` always returns 1 (pre-created window vout) and `libvlc_video_get_size` is a selected-track probe (binary disassembly during review) — `hasVideoOutput` is therefore `videoSize != nil` with the mechanism documented honestly. Invalidation on `.voutChanged` AND `.tracksChanged` (adaptive switches emit no size event) for both properties; dummy-vout decode confirmed 64×64 readable headless. Adaptive-switch device check rides the harness smoke screens. |
| P1.8 activeVideoOutputs | DONE | Stored, reset in `resetMediaDerivedState()` AND on the handle swap (the old handle's `voutChanged(0)` is source-filtered after reattach — review finding). |
| P0.5 SubtitleScale convenience | DONE (escape-hatch doc PENDING-DEVICE) | `init(approximatePoints:basePoints:)`, clamped; docs state the no-live-absolute-change limitation; `--freetype-fontsize` documented as experimental pending device validation (harness matrix (g) decides the final wording). Swap-survival test green. |
| P1.1 UA/app-id | DONE | Designated init widened in place (nil defaults byte-identical); `setUserAgent`/`setAppID`. Wire test against a local socket server: custom UA arrives as "MyIPTV/9.9 LibVLC/4.0.0-dev" (libVLC appends its token — asserted by prefix), nil default contains "SwiftVLC". Ungated, runs on CI. |
| §3.16 Volume 2.0 | DONE | Clamp 0…2.0, `.max` 2.0, docs + all six Showcase volume surfaces widened; wire-through test reads 200 natively (needs the real-aout instance — dummy aout has no volume control). |
| §3.16 porting guide | DONE | `VLCKitPortingGuide.md`: nine idiom sections, every claim symbol-linked; docc `--analyze` 0 warnings after disambiguating the case/accessor collisions (including pre-existing M2 ones). |

M3 review (2 lenses → 14 agents, 12 confirmed) drove: the session-gate fix,
`hasVideoOutput` semantics + invalidation, swap reset for the vout count,
the sparse-keyframe discriminating fixture, jump/seek(by:) F017+fast
completion, docc link repairs, and the Showcase volume surfaces. One
out-of-list fix: the M2 file split had left `nativeBackend` private while
the extracted `PiPController+Validation.swift` reads it — the iOS Showcase
scheme was silently broken at the M2 commit; fixed and all three schemes
rebuilt green.

Recorded test-plan deviations: no synthetic HLS-live unit test (valid HLS
needs real TS/fMP4 segments; live behavior is covered by the harness live
screens on hardware — matrix (f) + smoke screens).

## M4 — PiP — DONE (spike-independent scope; device-gated rest in PENDING-DEVICE)

| Item | Status | Evidence / notes |
|---|---|---|
| P0.6 restore hook — API + sample-buffer impl | DONE (landed upstream pre-rebase) | `onRestoreUserInterface` + the sample-buffer delegate restore method shipped on main in #54 (completion-handler shape, adopted as-is). Native-path interception is **spike-gated**: no implementation merged, per §4 rule 5. Spike steps 1–2 instrumentation ships in harness screen (c) (delegate-probe SPI). |
| P1.11 startsAutomaticallyFromInline | DONE | `PiPVideoView` knob plumbed to BOTH sites: the native drawable protocol method (was a literal `true`; now nonisolated, immutable-after-init) and the sample-buffer AVKit flag. Defaults preserve behavior. macOS accepts the knobs for symmetry, documented inert. |
| P2.16 managesAudioSession | DONE | `false` → category and activation both skipped; `true` → category at init, `setActive(true)` one-shot deferred to `start()` / first active intent / a willStart auto-PiP / an already-active-at-construction seed (the seed and willStart legs were review findings — the intent stream has no current-value replay). iOS-sim test suites assert no-touch and deferred activation. |
| P1.12 lifecycle events (sample-buffer half) | DONE | `PiPStopReason`/`PiPEvent` + `pipEvents` (Broadcaster-backed, unbounded, finished on deinit). `failedToStart` carries the previously-discarded error. Reasons: restore recorded before `onRestoreUserInterface` (sample-buffer path discriminates restore vs close TODAY thanks to the upstream hook); programmatic `stop()` records `.unknown` unconditionally (review fix — the start-animation window); `player.didReachEnd` → `.mediaEnded`; first-wins precedence documented + tested. Native path: synthesized `didStart`/`didStop(.unknown)` from the active flips; will/failed unavailable pending the spike — documented. recast/handle replacement → `didStop(.unknown)`, documented on `pipEvents` and `recast`. |
| F061 | DONE | The three @objc drawable selectors are `nonisolated`, bodies read immutable-after-init Sendable state, off-main contract documented; mutable access now fails to compile. |

AVKit ordering note (verified from the SDK header): restore is documented
before didStop; restore-vs-willStop ordering is undocumented — willStop
carries the best-known reason, didStop's is authoritative.

M4 verification: strict 0 warnings; 1502 tests green (CI + local); TSan/
ASan green (earlier in chain); Showcase iOS/macOS schemes build; tvOS
build-for-testing green; compact adversarial review (2 confirmed findings,
both fixed: activation seed hole, stop-reason gating window).

## M5b — Full harness + validation — DONE (device passes pending hardware)

All §3.13 deliverables ship: matrix screens (a)–(g) (a/c from M5a; b/d/e/f/g
new), one parameterized engine smoke screen instantiated for live TS / HLS
live / VOD / catch-up (start latency, decoded size, tracks/codecs,
statistics, seek probes), persisted PASS/FAIL/observation recording with
JSON export on every screen, config gating with disabled-row explanations,
`streams.local.example.json` committed, `streams.local.json` gitignored
(verified by `git check-ignore`), and a `HarnessHome` launch route.

Simulator validation runs (operator-style, local gitignored config pointing
at Apple's public bipbop streams for vod/adaptive/subtitled):
- iOS Showcase (iPhone 17 Pro sim): builds, installs, launches; root form
  shows the harness section; HarnessHome correctly reports "bundled
  streams.local.json" with missing keys (liveTS, hlsLive, catchup,
  audioOnly) and gates rows exactly as designed ((a) disabled, (b)–(e)
  enabled, (f) disabled); the Events case study plays the remote demo
  stream with video rendering and the lossless filtered event stream
  populating live (screenshots reviewed).
- tvOS Showcase (Apple TV 4K 3rd gen sim): builds, installs, launches; the
  Events case study plays with rendered video and live filtered events.
- PiP rendering is force-disabled in the simulator (`PiPVideoView.swift`
  simulator gate) — no PiP behavior was or could be validated in these
  runs; everything PiP-visual is in the PENDING-DEVICE ledger.

## Final verification (whole branch)

Every milestone ran the full chain at its boundary; the final state:
strict-concurrency build 0 warnings; `CI=true swift test --no-parallel`
green (1502 tests / 121 suites); local playback suite green; TSan + ASan
filters green; swiftlint --strict + swiftformat --lint clean repo-wide;
docc `--analyze` clean for all files touched this release; iOS/macOS/tvOS
Showcase schemes build; DynamicHost fixture verify.sh PASS (both
platforms + launch leg); tvOS simulator suite green (plus the one-off
ungated playback run for the §3.3 matrix).

## Branch hygiene pass (post-plan, user-requested)

A 7-group fan-out review of the full branch diff (dead code / stale
comments / transitional narration / scaffolding; every finding
adversarially verified) confirmed 30 findings, all fixed: unused imports
and never-exercised default parameters removed (EventBridge's coordinator
plumbing de-optionalized; single-caller timeout parameters inlined); every
"historical"/"this release"/"widened"/past-tense-narration comment
rewritten to the standing contract; stale docs corrected (close-button
delegate routing, `.unknown` reason clause, `hasVideoOutput` cross-ref,
vendor-manifest workflow comment); the misnamed shutdown-timing test
renamed; the undocumented lifetime-extension `_ =` replaced; the
`HarnessHome` route given its documented launch instruction; and
Package.swift restored to the pinned v0.9.1 url+checksum binaryTarget (the
local-path form was committed dev-state — `setup-dev.sh` applies it
uncommitted; a fresh clone now resolves, and the workflows'
`hashFiles('Package.swift')` cache keys carry the pin again). The earlier
"Local-dev note" about committing the flipped references is superseded for
Package.swift; the Showcase local-package reference remains committed (CI
runs `setup-dev.sh`, which tolerates both forms, and the local reference
builds everywhere now that the manifest is pinned).

Post-fix verification: strict build 0 warnings; 1502 tests green (CI and
local playback); TSan/ASan green; lint/format clean; docc --analyze 0
warnings; iOS Showcase scheme builds against the pinned manifest.

## Deviations log

1. §3.14 fixture uses two local packages instead of the single package PLAN
   sketched — Xcode 26 cannot build a dynamic product whose target is also
   consumed statically inside the same package. Topology contract unchanged;
   documented in IntegrationTopology.md.
2. P2.19 manifests are per-architecture (lipo-thinned) rather than raw `ar t`
   (which fails on fat archives). Strictly stronger check.
3. F036 scope grew: PLAN's "~34 sites" anchor covered the single-line guards;
   11 additional multi-line silent guards in the same suites were converted
   under the same rule, and 16 dead tests were revived with instances that can
   actually deliver their awaited conditions (see M0 table).
4. Two pre-existing tvOS-slice behavioral differences fixed in tests (not
   library code) — they predate v0.10.0 and were invisible before P1.13.

## PENDING-DEVICE ledger (hardware-only acceptance)

Prerequisite for all: build Showcase iOS to a physical iPhone/iPad (PiP is
simulator-blind), with `Showcase/iOS/ValidationHarness/streams.local.json`
filled per `streams.local.example.json` (liveTS, hlsLive, vod, catchup,
subtitled, adaptive, audioOnly). Record every outcome in each screen's
PASS/FAIL recorder and export the JSON.

1. **P0.6 spike, steps 1–5** — screen (c): with PiP active, tap "Probe
   native backend" (logs the window-controller class, AV controller
   presence, delegate class, and the five respondsToSelector results);
   exercise restore and X with no hook installed; zap channels and
   re-probe (delegate identity across vout rebuilds). Outcome decides
   go (forwarding proxy, plus P1.12's native will/did/failed events) vs
   no-go (libVLC-side patch; fork-liability re-estimate). The F062
   `pipMainActorSync` re-evaluation belongs in the same report. **No
   native-path restore implementation has been merged** — that is the
   gated work.
2. **P0.7 matrix (a)** — screen (a): PiP active → same-Player zaps across
   VOD→live, live→live, live→VOD; record window survival and gap/freeze
   per class. Survives → document the guarantee; closes → implement
   `resumesAcrossMediaReplacement` (design pre-sketched in PLAN §3.10).
3. **§3.15 matrix (e) — RELEASE-GATING** — screen (e): fullscreen playing
   with auto-PiP off → background: does audio continue, does timeChanged
   keep firing (the screen's once-per-second wall-clock log shows it on
   return), does video re-render on foreground; repeat with the
   audio-only stream. On stall: a background-policy fix is in scope
   before release per the plan. **The release does not ship with (e)
   unresolved.**
4. **P1.11 matrix (b)** — screen (b): auto-PiP engages with the flag on,
   stays inline with it off (toggle rebuilds the view).
5. **P0.3 matrix (d)/(d′)** — screen (d): recast to a real Chromecast
   sink mid-playback; resumes ≈ captured position; recast(to: nil)
   returns local; overlays/adjustments visually survive; record
   cast-start-while-PiP behavior.
6. **P0.1 matrix (f)** — screen (f): seek(toPosition:)/jump(by:) results
   against a real timeshift/catch-up stream (demuxer runtime property).
7. **P0.5 matrix (g)** — screen (g): whether `--freetype-fontsize=40`
   visibly changes subtitle size; then finalize the escape-hatch doc
   wording to state the observed result (currently marked experimental
   pending validation).
8. **P0.4 hardware leg** — smoke screens: decoded `videoSize` non-nil on
   a live channel with declared 0×0 dims; `videoSize` updates on an
   adaptive rendition switch.
9. **Engine smoke baseline** — run all four smoke screens once per
   release for the risk register (start latency, seek behavior, tracks,
   statistics per content class).
10. **AVAudioSession deactivation test** — `PlayerStopTeardownTests`'
    audio-session test executes on iOS/tvOS simulator runs without the
    CI variable (compiled green for both); run once on device alongside
    (e) for the full P1.10 acceptance.
