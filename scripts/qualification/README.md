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
  "artifactDigest": "…",
  "rows": [
    {
      "scenario": "vod-controls",
      "hardware": "iphone-current",
      "device": "iPhone 15 Pro",
      "os": "iOS 27.0",
      "fixture": "demo.mkv",
      "duration": "2m14s",
      "result": "pass",
      "notes": "optional; put log excerpts or anomalies here"
    }
  ]
}
```

`artifactDigest` is a SHA-256 over every slice's static library, in sorted
order. Get it for the artifact you are about to qualify with:

```bash
find Vendor/libvlc.xcframework -name '*.a' -type f -print0 \
  | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1
```

Headers and `Info.plist` are excluded deliberately: they carry no executable
behaviour, so a header-only change cannot invalidate a device run.

## Checking before release

```bash
./scripts/check-qualification.sh 1.1.0
```

It fails when the record is absent, describes a different artifact, is for
another version, omits a required row, contains a row that did not pass, or has
a row missing any of `device`, `os`, `fixture`, `duration` or `result`.

The digest is recomputed from the artifact on disk rather than trusted from the
record — a record can claim any digest, and only a recomputed one can contradict
it. That is what stops a stale qualification from carrying forward onto a
rebuilt engine.
