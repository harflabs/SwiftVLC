# Device qualification records

System Picture in Picture, native video output, audio teardown and real libVLC
playback cannot be validated by CI. It compiles the iOS tests but never executes
system PiP on hardware, and the sanitizer job links a *released* xcframework
rather than the engine under test. The physical-device matrix is therefore the
acceptance gate, and `release.sh` refuses to package an artifact without one.

## Running the matrix

`matrix.json` lists the required scenarios and hardware. A scenario without a
`hardware` list runs on every hardware row; focused performance, soak, and
failure scenarios name the exact hardware they require. The current matrix has
53 required rows. Simulator runs never satisfy a row: PiP is force-disabled
there, and a simulator can report PiP active while its window stays black.

The matrix covers the device-only acceptance criteria of every open v1.1.0
milestone issue, not only the original functional PiP matrix. Long-running
scenarios declare `minimumDurationSeconds`, and performance/failure scenarios
declare the non-empty fields their evidence JSON must contain. This makes the
release gate reject a brief smoke run or an evidence attachment that omits the
metric the issue asked us to qualify.

The matrix can also constrain the meaning of evidence, not just its presence.
`expectedEvidenceValues` requires an exact value (for example zero crashes),
while `allowedEvidenceValues` accepts one of a documented set (for example a
replacement session must be either preserved or boundedly re-engaged). This
prevents a passing row from carrying evidence that actually records an
unsupported feature, a regression, or a failed acceptance condition.
The original cross-device PiP rows apply the same rule to each control,
lifecycle order, recovery path, and stop reason; a top-level `result: "pass"`
cannot mask a failed pause, missing restoration, or unsuccessful recovery.

### Unattended physical-device lane

Once a device is connected, unlocked, trusted, and has Developer Mode enabled,
the smoke and regression lane is unattended. It does not require iPhone
Mirroring and does not ask an operator to copy observations out of the app:

```bash
./scripts/qualification/run-device-tests.sh \
  --derived-data /absolute/path/to/device-build \
  --output /absolute/path/to/evidence
```

That default path builds the app and runner from a clean checkout, embeds the
source commit and release-source digest in the signed app, and creates its
candidate metadata automatically. It builds a disposable `HEAD` export against
the exact local `Vendor/libvlc.xcframework`, so remote package resolution cannot
silently substitute an older wrapper or engine. A reused `--candidate-app` or `--skip-build`
requires `--candidate-metadata`; metadata creation succeeds only for an app
that was built with the `SwiftVLCSourceCommit` and
`SwiftVLCReleaseSourceDigest` Info.plist keys. The signed app also embeds
`SwiftVLCArtifactDigest`, and metadata creation rejects it unless that value
matches the complete XCFramework tree supplied to the runner. Use
`candidate-metadata.py source` before an external build to obtain those values,
then `candidate-metadata.py create` after signing to bind them to the app-tree
digest. Candidate metadata also records and verifies the complete XCFramework
tree digest; a signed app cannot be paired with evidence naming a different
engine artifact.

The command identifies the physical device and OS release type, generates and
serves deterministic local media, installs the exact signed candidate and UI
test runner, executes the analyzer, general UI stress suite, native/direct live
PiP, same-player continuity, capability convergence, terminal outcomes, the
adaptive HLS soak, both direct-PiP performance rows, and HLS seek lanes, then
pulls app logs and writes a machine-readable `report.json`. It retains every
attempt log and xcresult,
records and verifies candidate metadata that binds the app tree digest to its
source commit, release-source digest, and XCFramework digest, and retries only
a small allowlist of Xcode/device-launch infrastructure failures. Every run
reinstalls both exact signed apps; an assertion, product failure, or provenance
mismatch is never retried into a pass.

The live-media lane runs both native and direct PiP against the same indefinite
local stream. For each backend it verifies ordered start/stop events, AVKit's
unbounded linear-playback policy, three start/stop cycles, sustained real
system-PiP motion while backgrounded, foreground recovery, continued decoded
pictures, and zero library errors. It emits one combined `live-media` row so a
passing backend cannot hide a failure in the other.

The background-audio lane samples libVLC's native audio-output counter twice
inside a timed interval while the application state is actually backgrounded
and native PiP is active. A row is emitted only when played audio buffers
increased during that interval, PiP remained active with ordered lifecycle
events, and the app and host logs contain no library error records.

The continuity lane performs one focused VOD-to-live replacement and a second
VOD-to-live-to-VOD sequence on the same player while native PiP is active. It
records the successor generation, AVKit playback-policy snapshot, first video
and audio output gaps, PiP motion, ordered lifecycle, and any stale successor
event that escaped generation filtering. The two tests materialize independent
`replacement` and `replacement-continuity` rows from the same device run on
`iphone-current`. Other hardware runs only the matrix-wide `replacement` test
and row. Multi-row evidence is committed to the report only after every
expected attachment materializes successfully.

The iPhone-current-only capability-convergence lane runs VOD-to-live-to-VOD
transitions while PiP is active on both the native drawable and direct
sample-buffer backends. A
qualification-only fault injector drops raw length and seekability callbacks
from both independent Player and PiP-controller event consumers, forcing
Player's native polling to publish the capability. The test requires
finite seekable VOD to become interactive, unbounded live media to remain
linear, the successor VOD to become interactive again, the real AVKit skip
path to settle and advance playback, sustained system-PiP motion, and zero
library errors before emitting the combined `capability-convergence` row. The
default run omits this lane on other hardware rows, and an explicit unsupported
request fails before testing rather than producing evidence for an unknown row.

The VOD-controls lane runs on every hardware row and exercises both native
drawable and direct sample-buffer PiP with the real system window active.
Play and pause enter through the backend-specific control bridge, forward and
backward skips wait for their native landed outcome, and an absolute scrub
must settle on the public timeline without stopping PiP. Each backend is then
backgrounded and must show sustained system-PiP motion before a programmatic
stop completes the ordered lifecycle. One combined `vod-controls` attachment
is emitted only when every control passes on both backends with zero library
errors or unexpected stops.

The long-stall lane also runs on every hardware row. Its local fixture keeps a
continuous MPEG-TS connection flowing until the candidate has entered real
system PiP, then an explicit in-app trigger stalls every active connection for
twelve seconds. Both native and direct backends must publish either the public
stalled/recovered pair or the expected buffering/healthy transition, remain in
PiP, resume moving system-PiP pixels, and complete ordered teardown without
library errors. The app samples its own
resident memory throughout the fault and rejects growth beyond a 96 MiB bound;
the combined attachment records the raw per-backend timings and memory values
as well as the matrix-required recovery and bounded-memory outcomes.

The dismissal lane materializes the matrix-wide `restore` and `close` rows in
one hardware run. For native and direct backends, it starts real system PiP,
uses the moving-pixel oracle to locate the window, reveals SpringBoard's
controls, and taps the restore or close corner by normalized coordinates. This
avoids localized system labels while still exercising the real affordances.
Evidence is emitted only when restore invokes the host callback exactly once,
close invokes it zero times, and public lifecycle events report ordered
`restoreRequested` or `userClosed` reasons respectively. Each of the four app
launches writes a separate library log so an earlier backend/action error
cannot be overwritten by a later cycle.

The interruptions lane runs both PiP backends on every hardware row. The
separately installed XCTest runner activates a non-mixable playback audio
session while the candidate is backgrounded in real system PiP, then returns
focus with `notifyOthersOnDeactivation`; the candidate must observe a balanced
system interruption pair, recover playback, retain PiP, and render moving
pixels. Its libVLC played-audio-buffer counter must also advance beyond the
pre-interruption value, proving audio resumed rather than merely leaving the
player in a nominal playing state. Route-loss behavior is a distinct, explicitly labelled deterministic
injection: the candidate posts an `oldDeviceUnavailable` route-change
notification through the same shared `AVAudioSession` object observed by the
library. SwiftVLC must pause without closing PiP, accept an explicit resume,
and finish with ordered teardown. Evidence records both sources verbatim so a
controlled notification is never misrepresented as a physical Bluetooth
disconnect.

The iPhone-current-only deferred-pause-rejection lane drives the exact AVKit
playback command entry point while a qualification SPI changes only libVLC's
native pause-capability answer. It proves a permanently unpausable input
settles to `rejected` within the production retry bound without a late pause,
a transient three-probe rejection issues exactly one native pause, and newer
play, media replacement, and stop commands cancel pending work. The attached
evidence includes the individual counters and requires truthful AVKit/player
controls, zero endless tasks, zero duplicate pauses, and zero library errors.
The default run omits this lane on other hardware rows, and an explicit
unsupported request fails before testing.

The iPhone-current-only accepted-start-delayed-failure lane uses the direct
sample-buffer backend to issue a real AVKit start request, requires the
immediate result to be `accepted`, and then sends a deterministic asynchronous
failure through the installed AVKit delegate path. The candidate passes only
when the failure arrives before `didStart`, is the terminal recorded event, and
retains the controller and media generations captured at request time. The
attached evidence records those identities, ordered events, and injected error
domain. The default run omits this lane on other hardware rows, and an explicit
unsupported request fails before testing.

The same deterministic delegate-failure exercise also emits the matrix-wide
`failed-start` attachment on every hardware row. That narrower record requires
exactly one surfaced failure, no successful start, and ordered events; the
additional controller/media attribution fields remain reserved for the
iPhone-current `accepted-start-delayed-failure` row. The all-hardware lane
therefore closes the original functional matrix gap without weakening the
focused issue-104 qualification.
On the default `iphone-current` run, the harness materializes both attachments
from this single execution; either scenario remains independently selectable
with `--only`.

The HLS seek lane is another complete machine-readable matrix slice. It
executes forward, backward, and absolute seeks, measures the return of decoded
video, checks ordered PiP continuity, samples real system-PiP motion after each
seek, verifies inline recovery, and exports an XCTest JSON attachment. The host
materializes that attachment under `evidence/`, adding artifact, source, and
hardware identity fields that the test process is forbidden to provide. The
matching row appears under `qualificationRows` in `report.json`; beta-OS rows
remain exploratory and are rejected by `check-qualification.sh`.

The `adaptive-hls-soak` lane defaults to 7,200 seconds and runs only on the
`iphone-current` row. Its local origin constructs VOD, event, and sliding-live
playlists from deterministic low/high TS and fragmented-MP4 representations.
It injects discontinuities and one-shot HTTP failures, advances live windows,
and records successful retry, representation-transition, segment, and playlist
telemetry under a unique run token. The candidate cycles every mode without an
operator, samples Mach resident memory and Darwin malloc-zone totals every 30
seconds, and the host attaches Instruments' Allocations template with a rolling
15-minute stack-provenance window once the unique run token proves the exact
candidate has begun playback. The trace tree digest and table of contents are
added by the host to the candidate-bound evidence; inability to capture or
export that trace fails the row. The app scans native diagnostics for sanitizer signatures and fails on a
20-second unbounded recovery or more than 128 MiB final resident growth. The
attachment explicitly records whether ASan instrumentation was present; a zero
finding never pretends that a normal signed device build was ASan-instrumented.
`SWIFTVLC_ADAPTIVE_SOAK_SECONDS` may shorten an exploratory harness run, but
the matrix rejects any row shorter than 7,200 seconds.

The `pip-render-performance-1080p60` and
`pip-render-performance-4k60` lanes each run for 900 seconds on
`iphone-current`. The fixture generator creates short, local 60 fps H.264
sources at the real decoded dimensions; single-item `MediaListPlayer` loop mode drives
the same underlying `Player` continuously for the run. XCTest
starts direct sample-buffer PiP, backgrounds the app, locates the moving system
window, and repeatedly double-taps its normalized center to exercise the real
SpringBoard resize affordance. The candidate records Mach task CPU time, RSS,
thermal state, source and target geometry, conversion counts, presentation
rate, drops, bounded-pool failures, and the total, average, and maximum measured
wall time of the real Core Image conversion calls while replacing media on the
same player. Conversion timing is qualification-only and adds no clock reads to
the normal client hot path.
The runner sequentially attaches Instruments Game Performance, Power Profiler,
and Time Profiler captures, exports each table of contents, and binds every raw
trace tree digest into the evidence. The raw trace bundles and their exported
tables of contents are retained with the final qualification record and their
digests are revalidated during assembly. A missing trace, a target that never
changes, altered source geometry, more than 5% drops, less than 54 presented
frames per second, more than 160 MiB RSS growth, or any renderer failure rejects
the row. The app-side GPU/energy placeholders cannot satisfy the gate: host
augmentation removes them only after all three traces are verified.

The `cadence-matrix` lane runs for 600 seconds on `iphone-current`. Its local
origin serves deterministic 23.976, 24, 25, 29.97, 30, 50, 59.94, and 60 fps
H.264 sources plus a true 24/60 fps VFR source. Direct sample-buffer PiP stays
active while the app replaces all nine sources and performs pause/resume and
0.5x/1x/2x rate transitions. XCTest backgrounds the candidate and repeatedly
uses the real SpringBoard resize affordance. Evidence includes exact renderer
duration state (invalid rather than a nominal/average value), reported track
ratios, delivered/dropped/backpressure counters, generation-scoped PTS
monotonicity, replacement and resize targets, and compact raw samples. A
missing reported CFR cadence, fabricated duration, backward PTS, renderer
failure, more than 10% drops, incomplete transition, or unchanged render
target rejects the row. Every cadence fixture has a real 120-second timeline,
so phase completion does not depend on media options unsupported by the pinned
media-player API. `SWIFTVLC_CADENCE_SECONDS` may shorten exploratory runs, but the matrix
rejects release evidence shorter than 600 seconds.

Use `--require-stable` for release evidence. It fails before testing if the
device is a simulator, runs beta or unknown software, or does not match a
hardware row in `matrix.json`. Without that option, the same command is useful
for exploratory beta-OS testing, but its report remains ineligible for release.

This lane is intentionally fail-closed: its current automated scenarios are a
candidate qualification subset, not a claim that all 53 qualification rows
passed. `report.json` therefore keeps `releaseGateSatisfied` false until a
matrix runner has produced the complete candidate-bound records described
below. Remaining subtitle-format coverage, timebase soaks, and
every required hardware/OS row must still be represented by
automated evidence before the stable gate can open.

Qualification is bound to both halves of the shipped package. The
XCFramework tree digest identifies the native engine and headers, while the
release-source digest identifies every release-significant tracked file in the
Swift wrapper worktree. The latter deliberately excludes only the record for
the version being qualified and its `evidence/<version>/` attachments. It also
normalizes the narrowly validated Package.swift binary reference and Showcase
package reference, because candidate testing uses repo-local wiring and the
release commit deterministically replaces those fields with the final URL and
version. Any other tracked or untracked source, test, release-script, or matrix
change produces a different identity and requires a new candidate and device
run.

Record the results as `scripts/qualification/<version>.json`:

```json
{
  "version": "1.1.0",
  "artifactDigestAlgorithm": "swiftvlc-tree-v1",
  "artifactDigest": "…",
  "sourceCommit": "…",
  "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
  "releaseSourceDigest": "…",
  "qualificationMatrixChecksum": "…",
  "rows": [
    {
      "scenario": "vod-controls",
      "hardware": "iphone-current",
      "device": "iPhone 15 Pro",
      "deviceFamily": "iPhone",
      "productType": "iPhone16,1",
      "osVersion": "26.6",
      "osBuild": "23G80",
      "osReleaseType": "stable",
      "fixture": "demo.mkv",
      "duration": "2m14s",
      "durationSeconds": 134,
      "evidence": "evidence/v1.1.0/iphone-current-vod-controls.json",
      "result": "pass",
      "notes": "optional; put log excerpts or anomalies here"
    }
  ]
}
```

Every evidence file is a JSON object tied to the exact artifact and row:

```json
{
  "artifactDigest": "…",
  "releaseSourceDigest": "…",
  "scenario": "vod-controls",
  "hardware": "iphone-current",
  "events": {
    "started": true,
    "unexpectedStopCount": 0,
    "order": "pass"
  },
  "controls": {
    "pause": "pass",
    "scrub": "pass",
    "skipForward": "pass",
    "skipBackward": "pass"
  }
}
```

Scenario-specific required fields use dotted paths such as `metrics.cpu` or
`backendResults.native`. Zero is a valid recorded value (for example zero
crashes or frame drops); missing, null, empty strings, and empty collections
are not. Exact and allowed-value constraints use the same dotted-path syntax.
JSON types are strict: a boolean does not satisfy a numeric zero or one, even
inside an array or object. Durations must also be finite positive numbers;
`NaN` and infinity are rejected before minimum soak time is evaluated.
Evidence may contain any additional raw samples, logs, Instruments exports,
fixture hashes, or notes needed to make the result reproducible.

`artifactDigest` is a path-independent SHA-256 over the complete XCFramework
tree: libraries, headers, `Info.plist`, relative paths, symlinks, and modes.
Get it for the exact, already-stripped artifact you are about to qualify with:

```bash
./scripts/artifact-tree-digest.py Vendor/libvlc.xcframework
```

Do not strip, rewrite headers, or otherwise mutate the XCFramework after this
digest is recorded. A header-only ABI mismatch can be just as unsafe as a
library change.

Candidate preparation records the source commit, release-source digest, and
matrix checksum in `release-candidate.json`. Copy those values into the
qualification record and each evidence file. `check-qualification.sh` computes
the current identities itself and rejects stale source, a weakened or expanded
matrix, a record from another candidate, or evidence captured against another
wrapper revision.

Candidate-bound rows from separate device runs can be accumulated without
hand-editing JSON. Pass every retained `report.json` to the assembler, along
with the candidate metadata used by the device runner:

```bash
python3 scripts/qualification/assemble-record.py \
  --version 1.1.0 \
  --candidate-metadata /absolute/path/to/candidate-metadata.json \
  --matrix scripts/qualification/matrix.json \
  --report /absolute/path/to/iphone-results/report.json \
  --report /absolute/path/to/ipad-results/report.json \
  --output scripts/qualification/1.1.0.json
```

The assembler rejects exploratory or beta-OS reports, identity mismatches,
unknown or duplicate rows, failures, unsafe evidence paths, and evidence from a
different artifact, source, scenario, or hardware row. It copies accepted
attachments under `evidence/<version>/` and writes the record atomically. A
partial record is allowed so multiple devices can be accumulated over time;
only `check-qualification.sh` is the final gate, and it continues to reject the
record until all required rows and scenario-specific evidence pass.

## Checking before release

```bash
./scripts/check-qualification.sh 1.1.0
```

It fails when the record is absent, describes a different artifact, is for
another version, omits a required row, contains a row that did not pass, or has
a row missing device identity, stable OS build, fixture, duration, evidence, or
result. Evidence paths are relative to the record; each file must exist, parse
as JSON, name the same artifact/scenario/hardware, and contain the fields that
scenario requires with the required semantic values. It also rejects an
undersized soak, an iPhone recorded for an iPad row, the wrong OS major, and
beta OS software.

The digest is recomputed from the artifact on disk rather than trusted from the
record — a record can claim any digest, and only a recomputed one can contradict
it. That is what stops a stale qualification from carrying forward onto a
rebuilt engine.
