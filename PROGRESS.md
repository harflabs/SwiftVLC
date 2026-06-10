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

## M2 — Stop/teardown cluster (ONE unit) — PENDING

## M3 — Seek & playback info — PENDING

## M4 — PiP — PENDING (spike-independent items only; native-path is device-gated)

## M5b — Full harness + validation — PENDING

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

## PENDING-DEVICE ledger (hardware-only acceptance, accumulate as reached)

- (populated as milestones land)
