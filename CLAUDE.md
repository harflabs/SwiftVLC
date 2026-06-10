# SwiftVLC — Claude Code guide

Pure-Swift wrapper around libVLC 4.0 for iOS / macOS / tvOS / visionOS / Mac Catalyst. Swift 6.3, strict concurrency, `@Observable @MainActor Player`, typed `throws(VLCError)`, `AsyncStream` events. Current baseline: **v0.9.1** (tag `d6c7a56`).

## Active work: PLAN.md

[PLAN.md](PLAN.md) is the authoritative implementation plan for the next release (v0.10.0). Execute milestones **in order, M0 → M5** — the §4 coupling rules are binding, not advisory:

- **M0 first** (test/CI hardening + the §3.14 topology fixture) — everything after stands on it.
- **P2.14 lands with or before P0.2** (a lossy event stream structurally undermines a one-shot terminal event).
- **M2 is ONE unit** (P1.10 + P0.2 + P0.3 + riders): one branch, one review, one merge — they redefine the same stop/swap surfaces.
- **No M4 implementation beyond the spike-independent items** until the P0.6 spike reports go/no-go and matrix item (a) has device results.

Each PLAN.md item carries its own API spec, files-to-touch with `file:line` anchors, test plan, and acceptance criteria — treat acceptance criteria as the definition of done. Audit row IDs (F001, F036, …) and tier labels (P0.x, P1.x, P2.x) are stable identifiers from earlier maintainer review passes; every one that matters is fully described inline in PLAN.md.

## Working rules

- **All work stays local.** Never `git push`, open PRs, create tags/releases, or file/edit GitHub issues unless explicitly instructed in the moment. Reading remote state (`gh issue list`, `gh issue view`) is fine — PLAN.md §1 has the issue ledger (#34, #36, #37, #38, #43, #44, #45, #46, #48 are absorbed by the plan).
- **All v0.10.0 work happens on the local branch `v0.10.0-dev`** (already created off `main`/v0.9.1). Commit **locally** at minimum at every milestone boundary (M0 … M5), plus after the M2 unit lands as a whole — local commits only, never pushed. `main` stays untouched at v0.9.1.
- Pre-1.0: source-breaking API changes are acceptable when PLAN.md calls for them (e.g. F034), not otherwise.

## Building & testing

- `swift build` for a quick check; the repo must stay clean under `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` (0 warnings is the baseline).
- **Tests run against real libVLC — no mocks.** Full CI mirror: `CI=true swift test --no-parallel` (~1400 tests, ~35 s; video-output tests self-skip headless). Under `CI=true`, playback-driven race suites self-skip — M0 exists partly to fix that blind spot.
- Sanitizer runs mirror `.github/workflows/sanitize.yml` (TSan filter: `RaceTests|StressTests|MemoryTests|MemoryAndRetainTests|MemoryPressureTests|LifecycleStressTests`; ASan filter: `Memory|Broadcaster|EventBridge`).
- iOS/tvOS slices: `xcodebuild test` against a simulator destination (the macOS host `swift test` only type-checks the macOS slice; PLAN.md M0 adds the tvOS-simulator test job).
- The Showcase apps (`Showcase/`) are the manual-verification surface; the device-validation harness (PLAN.md §3.13) lives in Showcase iOS and reads a **gitignored** `streams.local.json` supplied by the operator — never commit stream URLs.
- `Vendor/libvlc.xcframework` is the pinned local binary; `scripts/build-libvlc.sh` rebuilds it (only needed if the P0.6 spike lands on its no-go branch).
- PiP is force-disabled in the simulator (`PiPVideoView.swift:320-327`) — every PiP acceptance criterion is device-only; don't claim PiP verification from simulator runs.

## Commit style

Imperative subject, focused body. Reference PLAN.md item IDs (e.g. "P0.2", "F036") in commit subjects so the plan's traceability survives into history.
