<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-light.svg">
  <img alt="SwiftVLC" src="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-light.svg" width="260">
</picture>

[![Tests](https://github.com/harflabs/SwiftVLC/actions/workflows/test.yml/badge.svg)](https://github.com/harflabs/SwiftVLC/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/harflabs/SwiftVLC/branch/main/graph/badge.svg)](https://codecov.io/gh/harflabs/SwiftVLC)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fharflabs%2FSwiftVLC%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/harflabs/SwiftVLC)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fharflabs%2FSwiftVLC%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/harflabs/SwiftVLC)

A Swift wrapper around [libVLC](https://www.videolan.org/vlc/libvlc.html) for iOS, macOS, tvOS, visionOS, and Mac Catalyst.

## Why?

AVFoundation covers Apple's native media stack well, but its container,
codec, subtitle, and network-protocol support stops at what Apple ships.
Apps that need MKV, SSA/ASS subtitles, SMB, UPnP, or other VLC-backed
formats need a broader engine. [VLC](https://www.videolan.org/)'s engine,
**libVLC**, provides exactly that through embeddable C APIs.

VideoLAN's Apple wrapper, [VLCKit](https://code.videolan.org/videolan/VLCKit),
is written primarily in Objective-C, with delegates, KVO,
`NSNotificationCenter`, and manual thread management — a faithful reflection
of the era it was designed in.

**SwiftVLC** wraps libVLC 4.0 directly in Swift, with no Objective-C layer
in between. It is built for `@Observable`, `async`/`await`, and
`VideoView(player)`.

## SwiftVLC vs VLCKit

| | SwiftVLC | VLCKit |
|---|---|---|
| **Language** | Swift 6 | Objective-C |
| **Bindings** | Direct C → Swift | C → Objective-C → Swift bridging |
| **State management** | `@Observable`, drives SwiftUI directly | KVO, `NSNotificationCenter`, delegates |
| **Concurrency** | `@MainActor`, `Sendable`, `async`/`await` | Manual thread dispatch, no isolation |
| **Video rendering** | `VideoView(player)` | App-supplied view setup plus drawable configuration |
| **Errors** | Typed, exhaustive `throws(VLCError)` | `NSError` codes |
| **Events** | `AsyncStream<PlayerEvent>`, multi-consumer | `NSNotificationCenter` |
| **libVLC generation** | 4.0 | 3.x stable line; 4.0 alpha packages exist |
| **SwiftUI PiP** | iOS via libVLC's native AVKit-backed drawable path; macOS private backend is SPI opt-in | App-supplied integration |
| **Swift 6 safe** | Yes, under strict concurrency | No |

A detailed comparison and a migration path live in the
[Comparison with VLCKit](https://swiftpackageindex.com/harflabs/swiftvlc/documentation/swiftvlc/comparisonwithvlckit)
and [VLCKit porting](https://swiftpackageindex.com/harflabs/swiftvlc/documentation/swiftvlc/vlckitportingguide)
guides.

## Features

- `@Observable` player: state, current time, duration, tracks, and volume drive SwiftUI directly.
- `VideoView(player)` handles the rendering lifecycle in a single SwiftUI view.
- Typed `throws(VLCError)` instead of error codes, plus an observable `player.failure` (`PlaybackFailureKind`) that attributes a failure to the source, demux, decoder, renderer, or output boundary.
- Lossless `player.terminalOutcomes`: exactly one frozen result per playback generation, captured before `.stopped` resets the observable timeline.
- Asynchronous media parsing: `try await media.parse()`, with cancellation.
- 10-band equalizer with libVLC's built-in presets.
- A-B looping, playback-rate control, and subtitle and audio delay.
- Semantic text subtitles: opt in to `player.textSubtitleStream()` for ordered region snapshots with WebVTT placement.
- Picture-in-Picture on iOS with full playback controls. macOS native PiP is an explicit private-API SPI opt-in; its panel takes the picture's shape rather than letterboxing inside the host view's.
- Media and renderer discovery through the bundled libVLC plugins. Bonjour-backed discovery runs on a SwiftVLC-owned run-loop thread, so it works without an active main run loop.
- 360° video with full viewpoint control over yaw, pitch, roll, and field of view.
- Asynchronous thumbnail generation at arbitrary timestamps.
- `MediaListPlayer` for playlist playback with loop and repeat modes.

## Requirements

- Swift 6.3+ / Xcode 26.4+
- iOS 18+ / macOS 15+ / tvOS 18+ / visionOS 2+ / Mac Catalyst 18+

## Installation

In Xcode, choose **File → Add Package Dependencies** and paste the
repository URL; Xcode picks up the latest release automatically:

```
https://github.com/harflabs/SwiftVLC.git
```

From a `Package.swift` manifest, add a dependency pinned to the current
release — the version string is on the
[releases page](https://github.com/harflabs/SwiftVLC/releases):

```swift
.package(url: "https://github.com/harflabs/SwiftVLC.git", from: "1.0.0")
```

SPM downloads the pre-built libVLC xcframework for you. It is a large
binary: the release zip is around 380 MB and expands to roughly 1 GB.

## Quick Start

```swift
import SwiftUI
import SwiftVLC

struct PlayerView: View {
  @State private var player = Player()

  var body: some View {
    VideoView(player)
      .onAppear {
        try? player.play(url: URL(string: "https://example.com/video.mp4")!)
      }
  }
}
```

`Player.play(url:)` expects a direct media stream or file URL. It does not
resolve `.pls` or classic `.m3u` playlist containers; use `MediaListPlayer`,
or fetch the playlist and extract its inner stream URL first. HLS `.m3u8`
URLs work directly, because they are streaming manifests rather than
playlists of separate media URLs.

### Common operations

```swift
// Playback
let player = Player()
try player.play(url: videoURL)
player.pause()
player.resume()
try player.seek(to: PlaybackPosition(0.5))  // 50% of the timeline
try player.seek(by: .seconds(-10))
try player.setPlaybackRate(1.5)
try player.setAudioVolume(0.8)
player.isMuted = true
player.stop()

// Tracks
player.selectedSubtitleTrack = player.subtitleTracks[1]

// Metadata
let media = try Media(url: videoURL)
let metadata = try await media.parse()
print(metadata.title ?? "untitled", metadata.duration ?? .zero)

// Events
for await event in player.events {
  switch event {
  case .stateChanged(let state): ...
  case .timeChanged(let time): ...
  default: break
  }
}
```

A successful `setPlaybackRate(_:)` means libVLC accepted the request, not
that the active input kept that rate — resolution is asynchronous inside
VLC. `player.rate` is the authoritative live value. When
`Player.supportsEffectivePlaybackRateEvents` is true,
`player.effectivePlaybackRateResolutions` reports the effective control
state libVLC settled on; those values carry no request correlation and are
not throughput measurements.

## Documentation

The API reference and task guides for the latest published release are
hosted on Swift Package Index:
**[swiftpackageindex.com/harflabs/swiftvlc/documentation](https://swiftpackageindex.com/harflabs/swiftvlc/documentation)**

Start with **Getting Started**, then **Playback Essentials** for the shape
of `Player` and **Displaying Video** for the rendering side. Feature guides
cover Picture-in-Picture, playlists, text subtitles, discovery and casting,
audio, video overlays, logging, the concurrency model, error handling, and
integration topology.

To build the documentation locally:

```bash
swift package --disable-sandbox preview-documentation --target SwiftVLC
```

## Showcase apps

`Showcase/` holds one folder, target, and scheme per platform lane:

- **iOS** — full-featured app target, also enabled for Mac Catalyst.
- **macOS** — the same coverage, adapted into a sidebar-driven Mac UI.
- **tvOS** — focus navigation and Siri Remote controls.
- **visionOS** — a focused simple-playback showcase.

Every target accepts an app-wide test stream URL. The override lives in
memory for the app session, is redacted in the UI to its scheme, host, and
a hidden path, and is used by showcases that otherwise load bundled or
public sample media. Any URL scheme the bundled libVLC supports is accepted
(HTTP, HTTPS, UDP, …), including HLS over HTTP(S).

- **iOS and Mac Catalyst:** **Set App-Wide Stream URL**, in the **Test Stream** section on the first screen.
- **macOS:** **Test Stream** in the toolbar, or **Test Stream URL** in the sidebar's **Configuration** section.
- **tvOS:** **Set App-Wide Stream URL** on the first screen; enter the URL with the on-screen keyboard or a paired device.
- **visionOS:** the **Test Stream** button beside the simple playback controls.

The showcase targets allow arbitrary network loads so user-entered HTTP
hosts work with libVLC. This broad App Transport Security exception is for
the Showcase apps only — applications embedding SwiftVLC should define the
narrowest transport policy their own media sources allow.

Showcase UI tests live under `Showcase/UITests/`: `iOS/` covers the broad
showcase flows, `macOS/` covers native macOS PiP, and `tvOS/` is a
placeholder target. The visionOS showcase has no UI-test target.

## Testing

The package suite uses
[Swift Testing](https://developer.apple.com/xcode/swift-testing/) against
the real libVLC binary, so regressions in the C bridge surface immediately
instead of hiding behind a fake. Showcase UI tests use XCTest separately.

```bash
swift test
```

Every pull request to `main` runs lint and policy checks, the package suite
with behavior/skip accounting, an iOS test-target compile, and an iOS
Showcase build. The full four-platform Showcase matrix, the tvOS simulator
run, and the sanitizers run after merge, on manual dispatch, or on a
release-candidate branch; sanitizers also run weekly. Real playback and
system-PiP acceptance stay in the physical-device checklist rather than
consuming hosted CI minutes.

Before a release candidate, connect a trusted, unlocked physical iPhone or
iPad with Developer Mode enabled and run the device checklist:

```bash
export SWIFTVLC_DEVELOPMENT_TEAM=ABCDE12345  # team shown in Xcode Settings
./scripts/qualification/qualify.sh full --version 1.1.0 \
  --device "My iPhone" --require-stable
```

The `full` profile takes roughly an hour and reports broad functional
confidence without pretending it ran the multi-hour endurance matrix. The
`release` profile keeps those real durations (around 8.5 hours on a current
iPhone) and must be run for each required device row before the stable
release gate can pass. Neither command publishes a release. The team is
applied only to a disposable source export with team-scoped bundle
identifiers; the checked-out Xcode project is not rewritten. See
[the device qualification guide](scripts/qualification/README.md) for
profiles, evidence, and checklist semantics.

[ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy) covers test tags,
fixtures, and suite structure.

## Development setup

```bash
git clone https://github.com/harflabs/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
swift test
```

`main` records an exact libVLC release URL and checksum. `setup-dev.sh`
verifies that tag against the GitHub asset digest, downloads that exact
artifact into `Vendor/`, and flips `Package.swift` plus the Showcase
package reference to repo-local sources. It never follows GitHub's mutable
"latest" pointer.

| `setup-dev.sh` flag | Effect |
|---|---|
| *(none)* | Install the exact release declared by `Package.swift`; replace an unverified or stale `Vendor/` copy. |
| `vX.Y.Z` *(positional)* | Pin to a specific release tag. |
| `--force` | Re-download even if `Vendor/` already exists. |
| `--skip-download` | Only flip local references (`Package.swift` and the Showcase app). Expects `Vendor/` to exist — useful after `build-libvlc.sh`. |

## Building libVLC from source

Needed only when bumping `VLC_HASH`, changing the patch series, or
preparing a release. Day-to-day Swift development does not require it.

```bash
brew install autoconf automake libtool cmake pkg-config gettext
mkdir -p /Volumes/ExternalSSD/SwiftVLC-Native
./scripts/build-libvlc.sh \
  --build-root=/Volumes/ExternalSSD/SwiftVLC-Native \
  --clean-build --all
```

A full `--all` build takes tens of minutes on Apple Silicon. The script
clones VLC at a pinned commit into `scripts/.build-libvlc/`, applies the
hash-locked patch manifest, builds every contrib (FFmpeg, dav1d, x264,
libass, …) per slice, and assembles `Vendor/libvlc.xcframework`.

A clean all-platform build needs roughly 100 GiB of working space. The
script checks the volume holding its working directory before compiling and
fails early when it is too small. Pass a canonical physical path for
`--build-root`; the script owns, and may remove, only the
`swiftvlc-libvlc-build` child beneath it.

That managed child carries an ownership marker, and an atomic
generation-bound lock prevents two builds from sharing the root. The script
refuses to remove an unmarked directory and never clears a stale lock on
its own — verify no build is active before inspecting or removing that
exact lock directory and its `.swiftvlc-lock-generation-v1` token. Cleanup
detaches the marked child atomically and walks it through no-follow
directory descriptors, refusing filesystem boundaries and replacement
races. An interrupted quarantine or publication staging is preserved and
reported for inspection rather than silently reused or deleted.

Source mutation, output assembly, and `Vendor/` publication each take a
one-use directory binding before entering an anchored working directory.
The XCFramework is built and validated in the external path, copied to a
private Vendor staging directory, and checked against its recorded tree
identity before replacing the previous artifact. Publication uses atomic
no-replace moves and writes provenance last, as the completion marker, so a
partial handoff cannot masquerade as a releasable artifact. These are
release-reproducibility and data-safety constraints, not coverage-only
tests.

An inexpensive source-contract lane replays the complete ordered patch
stack and exercises its mutation and behavior proofs without compiling VLC:

```bash
./scripts/validate-native-patch-series-source.sh \
  --work-root /absolute/path/on/external-ssd/native-source-validation
```

That lane includes the libaom 3.13.2 / NASM 3 consumer contract added after
a real macOS x86_64 rebuild exposed libaom 3.13.1's obsolete one-topic help
probe: it runs the fixed CMake logic against realistic split NASM 3 help
and proves the old probe still reproduces the failure. It also enforces
patch 0040's stopped-video-output lifecycle rule; a native macOS build runs
the same contract against the assembled archive in two watchdog-bounded
headless processes (early stop/release, and natural EOF/release after
renderer creation fails), turning a teardown deadlock into a bounded build
failure instead of an indefinite hang.

### Platform selection

| Flag | Platforms |
|---|---|
| *(default)* | iOS device + simulator |
| `--all` | iOS, tvOS, visionOS, macOS, Mac Catalyst (eight slices) |
| `--ios-only` / `--tvos-only` / `--visionos-only` / `--macos-only` / `--catalyst-only` | Replaces `Vendor/` with that single platform |
| `--tvos` / `--visionos` / `--macos` / `--catalyst` | Adds a platform to the default set |
| `--clean` / `--clean-build` | Wipe the managed build directory (the latter rebuilds afterwards) |
| `--build-root=<absolute-dir>` | Use `<absolute-dir>/swiftvlc-libvlc-build`; the root must already exist outside the checkout |
| `--hash=<sha>` | Override the pinned VLC commit |

> `*-only` flags **replace** the xcframework; any slices already in `Vendor/` are lost.

### Two-clean-build reproducibility proof

A release needs two complete `--clean-build --all` invocations from the
same committed SwiftVLC revision, on the same unchanged host toolchain and
with the same `MAKEFLAGS`. Use separate checkouts, but pass both
invocations the identical canonical external `--build-root`: VLC and some
contribs retain configure and source paths in live string data, so
different working roots are different build inputs even after stripping.
The shared root is locked against concurrent use, and each `--clean-build`
still removes the whole managed child before cloning and compiling.

```bash
mkdir -p /Volumes/ExternalSSD/SwiftVLC-Repro
./scripts/build-libvlc.sh \
  --build-root=/Volumes/ExternalSSD/SwiftVLC-Repro \
  --clean-build --all
```

After build A completes, preserve and validate its actual artifact rather
than copying only its JSON record:

```bash
mkdir -p /absolute/path/to/repro/run-a
./scripts/canonical-libvlc-artifact.sh stage \
  Vendor/libvlc.xcframework \
  /absolute/path/to/repro/run-a/libvlc.xcframework \
  Vendor/libvlc-provenance.json
cp Vendor/libvlc-provenance.json \
  /absolute/path/to/repro/run-a/libvlc-provenance.json
```

Run build B in a different clean checkout at the same commit with the same
`--build-root`. From build B's checkout, compare both retained artifacts
and records, then retain A's record beside B's artifact:

```bash
python3 scripts/libvlc-provenance.py compare \
  --first-provenance /absolute/path/to/repro/run-a/libvlc-provenance.json \
  --first-xcframework /absolute/path/to/repro/run-a/libvlc.xcframework \
  --second-provenance Vendor/libvlc-provenance.json \
  --second-xcframework Vendor/libvlc.xcframework \
  --output Vendor/libvlc-reproducibility.json

cp /absolute/path/to/repro/run-a/libvlc-provenance.json \
  Vendor/libvlc-provenance-a.json

python3 scripts/libvlc-provenance.py verify-proof \
  --proof Vendor/libvlc-reproducibility.json \
  --first-provenance Vendor/libvlc-provenance-a.json \
  --second-provenance Vendor/libvlc-provenance.json \
  --current-provenance Vendor/libvlc-provenance.json \
  --xcframework Vendor/libvlc.xcframework
```

The comparison hashes both provenance records, verifies each XCFramework
against its record, and requires the same full 40-character SwiftVLC commit
plus ordered, distinct clean-build UUIDs and UTC completion timestamps.
Starting a new native build removes the retained A record and the old
proof, so evidence from a previous commit cannot survive beside a new
artifact. The prepared candidate and the GitHub release retain both records
and the proof.

This is local operator evidence, not a cryptographic attestation that two
commands physically executed: anyone able to fabricate every artifact and
record on the release Mac can fabricate the evidence too. Preserve both
build logs, or use independently attested builders, when the stronger
supply-chain claim is required.

### Build adjustments and source patches

VLC master needs several build adjustments for SwiftVLC's supported Apple
toolchains. The script applies them in-tree on every invocation,
idempotently:

1. **Mac Catalyst.** Teaches VLC's build system the `macabi` target triple and guards OpenGLES-only code paths.
2. **visionOS deployment target.** Adds the `xros` target triple so object files are stamped with visionOS 2.0 instead of the installed SDK version.
3. **Xcode 26 LDFLAGS.** Adds `-isysroot` to linker invocations so libSystem resolves.
4. **libtool 2.5 OBJC tag.** Adds `_LIBTOOLFLAGS = --tag=CC` to the `Makefile.am` files containing `.m` sources. Older libtool inferred the tag; 2.5 refuses.
5. **Rust contribs disabled.** VLC's contribs pin `cargo-c 0.9.29`, which pulls `time 0.3.31` and fails type inference under the supported Rust toolchain. The only Rust contrib on Apple is `rav1e` (an AV1 *encoder*); `dav1d` handles decoding.
6. **`dup3` / `pipe2`.** Forced unavailable via autoconf cache vars. The iOS Simulator SDK 26 exports these Linux-only syscalls from libSystem, fooling configure into using them.

On top of those, an ordered series of 71 hash-pinned source patches is
declared in
[`scripts/patches/manifest.sha256`](scripts/patches/manifest.sha256). Each
patch documents its purpose at the top of the file. Verify the series with
`./scripts/verify-patch-manifest.sh`; the build refuses missing, unlisted,
or modified patches.

`git reset --hard` runs only when HEAD is not at `VLC_HASH`, so the patches
and per-platform build directories survive repeated runs.

## Releasing

Releases advance `main`, but a stable release can only consume an
immutable, previously prepared and device-qualified candidate. The 1.1.0
line requires native extension v12 together with the v8 Apple
audio-session lease refinement, so a candidate must be built from the
current patch manifest.

```bash
./scripts/build-libvlc.sh \
  --build-root=/absolute/path/to/shared-native-root \
  --clean-build --all                    # run twice; retain the proof above
./scripts/release.sh X.Y.Z --dry-run     # strip + zip + checksum, no push
./scripts/release.sh X.Y.Z --status      # cheap read-only readiness report
./scripts/release.sh X.Y.Z --prepare /absolute/path/to/candidate
./scripts/check-qualification.sh X.Y.Z /absolute/path/to/candidate/libvlc.xcframework
# Stage a non-SemVer candidate tag, authenticated draft, and exact CI branch.
./scripts/release.sh X.Y.Z --candidate /absolute/path/to/candidate
# After exact-commit workflows pass, atomically assign the SemVer tag + publish.
./scripts/release.sh X.Y.Z --candidate /absolute/path/to/candidate --finalize
# Betas use the same prepare/stage/finalize flow but skip device qualification.
./scripts/release.sh X.Y.Z-beta.1 --prepare /absolute/path/to/beta-candidate
./scripts/release.sh X.Y.Z-beta.1 --candidate /absolute/path/to/beta-candidate
./scripts/release.sh X.Y.Z-beta.1 --candidate /absolute/path/to/beta-candidate --finalize
```

Release mode comes from the validated SemVer tag. A version with a
pre-release component (`1.1.0-beta.1`) is always marked unqualified and
published as a GitHub pre-release. A stable version cannot use
`--unqualified`; it must consume a prepared candidate and pass the complete
device and feature gates.

In outline: `--prepare` verifies the eight slices, strips and zips once, and
records the tree, zip, both provenance records, the reproducibility proof and
the qualification policy as an immutable candidate. Device qualification then
binds to that exact post-strip tree. `--candidate` rewrites `Package.swift` and
the Showcase pin, creates the release commit, and pushes only
`swiftvlc-candidate-vX.Y.Z-<full SHA>` — a deliberately non-SemVer tag, so
SwiftPM cannot resolve the version — plus a draft release that only
exact-commit CI can read. `--finalize` requires Tests, Fixtures, Vendor
manifest, Native source contracts and Sanitizers to have passed on that exact
commit, publishes the draft as `vX.Y.Z`, verifies the immutable release, its
attestation, an anonymous download and an external SwiftPM build, and only then
fast-forwards `main`. [ARCHITECTURE.md](ARCHITECTURE.md#release-flow) has the
full flow and its invariants.

Staging is safe to pause: a failed upload or missing, pending or failed CI
leaves only the non-SemVer tag and a non-public draft, and `main` does not
move. Rerun the same phase; it reconciles remote state rather than repeating
blindly. Never delete, move, or reuse a final public release tag.

Each release invocation retains `output.log` and `phases.json` in the
temporary directory printed at startup. The default limits are one hour
overall and ten minutes without output; `SWIFTVLC_RELEASE_WALL_SECONDS` and
`SWIFTVLC_RELEASE_IDLE_SECONDS` can set explicit limits, up to 24 hours.
Timeouts stop the process group and preserve the phase timings. After an
interrupted upload or publication, run
`--status --candidate /path/to/candidate` and rerun the same phase: the
normal checks reconcile remote state and retain verified uploads. Status
reports local prerequisites and visible PR checks only — it does not verify
artifact bytes or grant qualification or publication credit.

A Swift, test, release-tooling, or content-addressed native-inventory
correction can reuse a previously prepared candidate or a verified
clean-build output:

```bash
./scripts/release.sh X.Y.Z --prepare /path/to/new-candidate \
  --reuse-native /path/to/old-candidate-or-build-output
```

This requires unchanged native inputs between the original build commit and
the current clean checkout. A build-output directory must contain the
complete XCFramework, both provenance records, and the reproducibility
proof from the two clean builds. Unknown paths, and changes to native code,
patches, build configuration, or validators, require a rebuild. Both
original provenance records and the proof stay unchanged. The new candidate
binds the current Swift source and qualification policy, records the
original `nativeSourceCommit`, and requires fresh CI and — for stable
releases — physical qualification. An already staged candidate is never
silently replaced.

Ordinary PRs that change native inputs compile the patched macOS engine and
run 20 ordering-probe repetitions against its final archive, followed by
Swift behavior tests, before the required `test` check can pass. The Tests
workflow also exposes a manual `build-native` input for exercising this
lane. It checks macOS integration only; release preparation still requires
the full eight-slice build and the reproducibility proof. CI records the
effective toolchain and SDK and includes that identity in compiled-cache
keys.

For a hosted runtime failure, manually dispatch **Native artifact
diagnostics** to repeat the strict frame-step probe against the declared
public engine without another native build; its logs include submission
baselines and terminal counts. Failed clean builds retain their unpublished
XCFramework and host configuration for diagnosis, and those artifacts carry
no release or qualification approval. For source-linked failures, dispatch
the same workflow with `retained-run` set to the failed Tests run ID: it
replays the exact compiler checkout recorded in that run's log and
exercises the current probe against the retained engine and generated
headers without recompiling VLC. These diagnostic runs can expose defects
in older engines; required CI uses the engine built from the current
changes.

After publication, confirm that Swift Package Index has finished building
the tagged API reference and that the unversioned documentation link
resolves to the new release. That build is asynchronous and may serve the
previous release while the new tag is queued.

## Architecture

For internals — module design, C interop, the concurrency model, the event
system, memory management, and the PiP rendering pipeline — see
**[ARCHITECTURE.md](ARCHITECTURE.md)**.

## License

MIT. See [LICENSE](LICENSE).

libVLC is licensed under
[LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Static
linking may have licensing implications; see the
[VLC licensing FAQ](https://www.videolan.org/legal.html).

## Acknowledgments

SwiftVLC stands on the work of the [VideoLAN](https://www.videolan.org/)
community. VLC and libVLC represent decades of media playback work by
hundreds of contributors. Thanks also to
[VLCKit](https://code.videolan.org/videolan/VLCKit) for establishing libVLC
on Apple platforms.
