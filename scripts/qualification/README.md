# Device qualification records

System Picture in Picture, native video output, audio teardown and real libVLC
playback cannot be validated by CI. It compiles the iOS tests but never executes
system PiP on hardware, and the sanitizer job links a *released* xcframework
rather than the engine under test. The physical-device matrix is therefore the
acceptance gate, and `release.sh` refuses to package an artifact without one.

## Running the matrix

`matrix.json` lists the required scenarios and hardware. Every combination is
required — 9 scenarios across 4 hardware rows. Simulator runs never satisfy a
row: PiP is force-disabled there, and a simulator can report PiP active while
its window stays black.

Record the results as `scripts/qualification/<version>.json`:

```json
{
  "version": "1.1.0",
  "artifactDigestAlgorithm": "swiftvlc-tree-v1",
  "artifactDigest": "…",
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
      "evidence": "evidence/v1.1.0/iphone-current-vod-controls.json",
      "result": "pass",
      "notes": "optional; put log excerpts or anomalies here"
    }
  ]
}
```

`artifactDigest` is a path-independent SHA-256 over the complete XCFramework
tree: libraries, headers, `Info.plist`, relative paths, symlinks, and modes.
Get it for the exact, already-stripped artifact you are about to qualify with:

```bash
./scripts/artifact-tree-digest.py Vendor/libvlc.xcframework
```

Do not strip, rewrite headers, or otherwise mutate the XCFramework after this
digest is recorded. A header-only ABI mismatch can be just as unsafe as a
library change.

## Checking before release

```bash
./scripts/check-qualification.sh 1.1.0
```

It fails when the record is absent, describes a different artifact, is for
another version, omits a required row, contains a row that did not pass, or has
a row missing device identity, stable OS build, fixture, duration, evidence, or
result. Evidence paths are relative to the record and must exist. It also
rejects an iPhone recorded for an iPad row, the wrong OS major, and beta OS
software.

The digest is recomputed from the artifact on disk rather than trusted from the
record — a record can claim any digest, and only a recomputed one can contradict
it. That is what stops a stale qualification from carrying forward onto a
rebuilt engine.
