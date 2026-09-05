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

AVFoundation is excellent for Apple's native media stack, but its
container, codec, subtitle, and network-protocol support is limited to
what Apple ships. Apps that need MKV, SSA/ASS subtitles, SMB,
UPnP, or other VLC-backed formats and protocols need a broader engine.

[VLC](https://www.videolan.org/)'s engine, **libVLC**, supports a broad set of codecs, containers, subtitles, and network protocols through embeddable C APIs.

VideoLAN's Apple wrapper, [VLCKit](https://code.videolan.org/videolan/VLCKit), is written primarily in Objective-C. It uses delegates, KVO, `NSNotificationCenter`, and manual thread management, which is a faithful reflection of the era it was designed in.

**SwiftVLC** wraps libVLC 4.0 directly in Swift, with no Objective-C layer in between. It is built for `@Observable`, `async/await`, and `VideoView(player)`.

## SwiftVLC vs VLCKit

| | SwiftVLC | VLCKit |
|---|---|---|
| **Language** | Swift 6 | Objective-C |
| **Bindings** | Direct C → Swift | C → Objective-C → Swift bridging |
| **State management** | `@Observable`, drives SwiftUI directly | KVO, `NSNotificationCenter`, and delegates |
| **Concurrency** | `@MainActor`, `Sendable`, `async/await` | Manual thread dispatch, no isolation |
| **Video rendering** | `VideoView(player)` | App-supplied view setup plus drawable configuration |
| **Errors** | Library failures use `throws(VLCError)`, typed and exhaustive | `NSError` codes |
| **Events** | `AsyncStream<PlayerEvent>` with multiple consumers | `NSNotificationCenter` |
| **libVLC generation** | 4.0 | 3.x stable line; 4.0 alpha packages exist |
| **SwiftUI PiP** | iOS via libVLC's native AVKit-backed drawable path; macOS private backend is SPI opt-in | App-supplied integration |
| **Swift 6 safe** | Yes, with strict concurrency | No |

## Features

- `@Observable` player: state, current time, duration, tracks, and volume drive SwiftUI directly.
- `VideoView(player)` handles the rendering lifecycle in a single SwiftUI view.
- Library failures use typed `throws(VLCError)` instead of error codes.
- Asynchronous media parsing: `try await media.parse()` with cancellation support.
- 10-band equalizer with libVLC's built-in presets.
- A-B looping, playback rate control, and subtitle and audio delay.
- Picture-in-Picture on iOS with full playback controls; macOS native PiP is available only through an explicit private-API SPI opt-in.
- Media discovery and renderer discovery through services exposed by the bundled libVLC plugins.
- 360° video with full viewpoint control over yaw, pitch, roll, and field of view.
- Asynchronous thumbnail generation at arbitrary timestamps.
- `MediaListPlayer` for playlist playback with loop and repeat modes.

## Requirements

- Swift 6.3+ / Xcode 26.4+
- iOS 18+ / macOS 15+ / tvOS 18+ / visionOS 2+ / Mac Catalyst 18+

## Installation

In Xcode, choose **File → Add Package Dependencies**, paste the repo
URL, and Xcode will pick up the latest release automatically:

```
https://github.com/harflabs/SwiftVLC.git
```

From a `Package.swift` manifest, add a dependency and pin to the
current release. The version string lives on the
[releases page](https://github.com/harflabs/SwiftVLC/releases).

```swift
.package(url: "https://github.com/harflabs/SwiftVLC.git", from: "1.0.0")
```

The pre-built libVLC xcframework downloads automatically via SPM. It's a large binary (multi-GB unstripped; the release zip is a few hundred MB).

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

`Player.play(url:)` expects a direct media stream or file URL. It does
not auto-resolve `.pls` or classic `.m3u` playlist containers; use
`MediaListPlayer` or fetch and parse the playlist to its inner stream
URL before passing it to `Player`. HLS `.m3u8` URLs are supported here
because they are streaming manifests rather than playlists of separate
media URLs.

### Common Operations

```swift
// Playback
let player = Player()
try player.play(url: videoURL)
player.pause()
player.stop()
try player.seek(to: PlaybackPosition(0.5)) // Seek to 50%
try player.setPlaybackRate(1.5)            // Request 1.5x control rate
try player.setAudioVolume(0.8)             // 80% volume
player.isMuted = true

// Tracks
player.selectedSubtitleTrack = player.subtitleTracks[1]

// Metadata
let media = try Media(url: videoURL)
let metadata = try await media.parse()
print(metadata.title, metadata.duration)

// Events
for await event in player.events {
  switch event {
  case .stateChanged(let state): ...
  case .timeChanged(let time): ...
  default: break
  }
}
```

Playback-rate application is asynchronous inside VLC. A successful setter
return confirms immediate request acceptance, not that the active input kept
that rate. On extension-v7 builds, `player.effectivePlaybackRateResolutions`
reports the effective control state without claiming request correlation or
measured throughput; `player.rate` remains the authoritative live value.

## Documentation

The API reference for the latest published release is hosted on Swift Package
Index. The unversioned link follows the most recent tag that the service has
finished building:
**[swiftpackageindex.com/harflabs/swiftvlc/documentation](https://swiftpackageindex.com/harflabs/swiftvlc/documentation)**

## Showcase Apps

The `Showcase/` directory contains separate folders, targets, and schemes for each showcase lane:

- **iOS.** Full-featured app target, also enabled for Mac Catalyst.
- **macOS.** Native macOS app target with the same showcase coverage, adapted into sidebar-driven Mac UI.
- **tvOS.** Native tvOS showcase app target with TV-focused focus navigation and Siri Remote controls.
- **visionOS.** Native visionOS app target with a focused simple playback showcase.

Every showcase target accepts an app-wide test stream URL. The override is
kept in memory for the current app session, redacted to its scheme, host, and a
hidden path in the UI, and used by showcases that otherwise load bundled or
public sample media. HTTP, HTTPS, UDP, and other URL schemes supported by
the bundled libVLC are accepted, including HLS through its `.m3u8` HTTP(S)
URL.

- **iOS and Mac Catalyst:** open **Set App-Wide Stream URL** in the **Test Stream** section on the first screen.
- **macOS:** use **Test Stream** in the toolbar or **Test Stream URL** in the sidebar's **Configuration** section.
- **tvOS:** select **Set App-Wide Stream URL** on the first screen and enter the URL with the on-screen keyboard or a paired device.
- **visionOS:** use the **Test Stream** button beside the simple playback controls.

The development showcase targets allow arbitrary network loads so user-entered
HTTP hosts work with libVLC. This broad App Transport Security exception is for
the Showcase apps only. Applications embedding SwiftVLC should define the
narrowest transport policy appropriate for their own media sources.

Showcase UI tests live under `Showcase/UITests/`. `iOSUITests` covers
the broad showcase flows, `macOSUITests` covers native macOS PiP, and
`tvOSUITests` is a placeholder target. The visionOS showcase does not
have a UI-test target.

## Testing

The core package uses a comprehensive
[Swift Testing](https://developer.apple.com/xcode/swift-testing/) suite
against the real libVLC binary, so regressions in the C bridge surface
immediately rather than hiding behind a fake. Showcase UI tests use
XCTest separately. Every pull request to `main` runs lint and policy checks,
the package suite with behavior/skip accounting, an iOS test-target compile,
and an iOS Showcase build. The slower four-platform Showcase matrix, tvOS
simulator run, and sanitizers run after merge or when manually requested;
sanitizers also run weekly. Real playback and system-PiP acceptance stays in
the local physical-device checklist instead of consuming hosted CI minutes.

```bash
swift test
```

Before a release candidate, connect a trusted, unlocked physical iPhone or iPad
with Developer Mode enabled and run the human-facing device checklist:

```bash
export SWIFTVLC_DEVELOPMENT_TEAM=ABCDE12345  # team shown in Xcode Settings
./scripts/qualification/qualify.sh full --version 1.1.0 \
  --device "My iPhone" --require-stable
```

The approximately one-hour `full` profile reports broad functional confidence
without pretending it ran the multi-hour endurance matrix. The `release`
profile retains those real durations and must be run for each required device
row before the stable release gate can pass. Neither command publishes a
release. The team is applied only to a disposable source export with
team-scoped bundle identifiers; the checked-out Xcode project is not rewritten.
See [the device qualification guide](scripts/qualification/README.md)
for profiles, evidence, and checklist status semantics.

See [ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy) for test tags,
fixtures, and structure.

## Development Setup

```bash
git clone https://github.com/harflabs/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
swift test
```

`main` records an exact libVLC release URL and checksum. `setup-dev.sh` verifies
that tag against the GitHub asset digest, downloads that exact artifact into
`Vendor/`, and flips `Package.swift` plus the Showcase package reference to
repo-local sources. It never follows GitHub's mutable “latest” pointer.

| `setup-dev.sh` flag | Effect |
|---|---|
| *(none)* | Install the exact release declared by `Package.swift`; replace an unverified or stale `Vendor/` copy. |
| `vX.Y.Z` *(positional)* | Pin to a specific release tag. |
| `--force` | Re-download even if `Vendor/` already exists. |
| `--skip-download` | Only flip local references (`Package.swift` and the Showcase app). Expects `Vendor/` to already exist, which is useful after running `build-libvlc.sh`. |

## Building libVLC from Source

Needed only when bumping `VLC_HASH`, modifying build patches, or preparing a release. Day-to-day Swift development doesn't require it.

```bash
brew install autoconf automake libtool cmake pkg-config gettext
mkdir -p /Volumes/ExternalSSD/SwiftVLC-Native
./scripts/build-libvlc.sh \
  --build-root=/Volumes/ExternalSSD/SwiftVLC-Native \
  --clean-build --all
```

Expect a full `--all` build to take tens of minutes on Apple Silicon. By
default, the script clones VLC at a pinned commit into
`scripts/.build-libvlc/`. It applies the hash-locked patch manifest, builds
every contrib (FFmpeg, dav1d, x264, libass, …) per slice, and assembles the
result into `Vendor/libvlc.xcframework`.

A clean all-platform build needs roughly 100 GiB of working space. The script
checks the volume that contains its working directory before compiling and
fails early when it is too small. For an external SSD, create a dedicated root
and pass its canonical physical path; the script owns and may remove only the
`swiftvlc-libvlc-build` child beneath it:

```bash
mkdir -p /Volumes/ExternalSSD/SwiftVLC-Native
./scripts/build-libvlc.sh \
  --build-root=/Volumes/ExternalSSD/SwiftVLC-Native \
  --clean-build --all
```

The managed child carries an ownership marker, and an atomic generation-bound
lock prevents two builds from using the root concurrently. The script refuses
to remove an unmarked directory and never automatically clears a stale lock;
verify that no build is active before inspecting or removing that exact lock
directory and its `.swiftvlc-lock-generation-v1` token.
Cleanup detaches the marked child atomically and walks it through no-follow
directory descriptors, refusing filesystem boundaries or replacement races.
Any interrupted quarantine or publication staging is preserved and reported
for inspection instead of being silently reused or recursively deleted.

Source mutation, output assembly, and final `Vendor/` publication each use a
one-use directory binding before entering an anchored working directory. The
XCFramework is built and fully validated in the stable external path, copied
to a private Vendor staging directory, and checked against its recorded tree
identity before it replaces the previous artifact. Publication uses atomic
no-replace moves and writes provenance last as the completion marker, so a
partial handoff cannot masquerade as a releasable native artifact. These
constraints are part of the release reproducibility and data-safety contract,
not coverage-only tests.

The inexpensive source-contract lane replays the complete ordered patch stack
and exercises its mutation/behavior proofs without compiling VLC:

```bash
./scripts/validate-native-patch-series-source.sh \
  --work-root /absolute/path/on/external-ssd/native-source-validation
```

That lane includes the libaom 3.13.2/NASM 3 consumer contract added after a
real macOS x86_64 rebuild exposed libaom 3.13.1's obsolete one-topic help
probe. It runs the fixed CMake logic against realistic split NASM 3 help and
also proves that the old probe reproduces the failure.

It also enforces patch 0040's stopped-video-output lifecycle rule. A native
macOS build runs the same contract against the assembled archive in two
watchdog-bounded headless processes: early stop/release and natural
EOF/release after renderer creation fails. This turns a teardown deadlock into
a bounded build failure instead of letting a release build hang indefinitely.

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

A release needs two complete `--clean-build --all` invocations from the same
committed SwiftVLC revision, on the same unchanged host toolchain and with the
same `MAKEFLAGS`. Use separate checkouts, but pass both sequential invocations
the exact same canonical external `--build-root`. VLC and some contribs retain
configure/source paths in live string data, so different working roots are
different build inputs even after debug symbols are stripped. The shared root
is locked against concurrent use; each `--clean-build` still removes the entire
managed child before cloning and compiling from scratch.

For example, prepare the shared root once, then use the identical option in
both checkouts:

```bash
mkdir -p /Volumes/ExternalSSD/SwiftVLC-Repro
./scripts/build-libvlc.sh \
  --build-root=/Volumes/ExternalSSD/SwiftVLC-Repro \
  --clean-build --all
```

After build A completes, preserve and validate its actual artifact rather than
copying only its JSON record:

```bash
mkdir -p /absolute/path/to/repro/run-a
./scripts/canonical-libvlc-artifact.sh stage \
  Vendor/libvlc.xcframework \
  /absolute/path/to/repro/run-a/libvlc.xcframework \
  Vendor/libvlc-provenance.json
cp Vendor/libvlc-provenance.json \
  /absolute/path/to/repro/run-a/libvlc-provenance.json
```

Run build B in a different clean checkout at the same commit, with the same
`--build-root` command shown above. From build B's checkout, compare both
retained artifacts and records, then retain A's record beside B's selected
artifact:

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

The comparison hashes both full provenance records, verifies each actual
XCFramework against its record, and requires the same full 40-character
SwiftVLC commit plus ordered, distinct clean-build UUIDs and UTC completion
timestamps. Starting any new native build removes the retained A record and old
proof, so evidence from a previous commit cannot silently survive beside a new
artifact. The prepared candidate and GitHub release retain both records plus the
proof. This closes accidental reuse and the former "copy JSON, edit UUID"
shortcut. It is still local operator evidence, not a cryptographic attestation
that two commands physically executed: someone able to fabricate all artifacts
and records on the release Mac can fabricate the local evidence too. Preserve
both build logs, or use independently attested builders when that stronger
supply-chain claim is required.

### Build adjustments and source patches

VLC master requires several build adjustments for SwiftVLC's supported Apple
toolchains. The script applies them in-tree on every invocation, idempotently:

1. **Mac Catalyst.** Teaches VLC's build system the `macabi` target triple and guards OpenGLES-only code paths.
2. **visionOS deployment target.** Adds the `xros` target triple so object files are stamped with visionOS 2.0 instead of the installed SDK version.
3. **Xcode 26 LDFLAGS.** Adds `-isysroot` to linker invocations so libSystem resolves.
4. **libtool 2.5 OBJC tag.** Adds `_LIBTOOLFLAGS = --tag=CC` to the `Makefile.am` files that contain `.m` sources. Older libtool versions inferred the tag; 2.5 refuses.
5. **Rust contribs disabled.** VLC's contribs pin `cargo-c 0.9.29`, which pulls `time 0.3.31` and fails type inference under the supported Rust toolchain. The only Rust contrib on Apple is `rav1e` (AV1 *encoder*); `dav1d` handles decoding.
6. **`dup3` / `pipe2`.** Forced unavailable via autoconf cache vars. iOS Simulator SDK 26 exports these Linux-only syscalls from libSystem, fooling configure into using them.

The ordered, hashed source-patch series is declared in
[`scripts/patches/manifest.sha256`](scripts/patches/manifest.sha256). Each
patch documents its purpose at the top of the file. Verify the series with
`./scripts/verify-patch-manifest.sh`; the build refuses missing, unlisted, or
modified patches.

`git reset --hard` only runs when HEAD is not at `VLC_HASH`, so the patches and per-platform build dirs survive repeated runs.

## Releasing

Releases advance `main`, but stable releases can only consume an immutable,
previously prepared and device-qualified candidate. `setup-dev.sh` flips a
working checkout back to local sources for day-to-day development.

The 1.1.0 release line now requires native extension v10 together with the v8
Apple audio-session lease refinement. The published `1.1.0-beta.9` archive
carries v9 and remains usable through the fail-closed weak compatibility path,
but it cannot pass the current release gate. The first eligible candidate must
be rebuilt from the current patch manifest.

```bash
./scripts/build-libvlc.sh \
  --build-root=/absolute/path/to/shared-native-root \
  --clean-build --all                    # run twice; retain proof above
./scripts/release.sh X.Y.Z --dry-run     # strip + zip + checksum, no push
./scripts/release.sh X.Y.Z --prepare /absolute/path/to/candidate
./scripts/check-qualification.sh X.Y.Z /absolute/path/to/candidate/libvlc.xcframework
# Stage a non-SemVer candidate tag, authenticated draft, and exact CI branch.
./scripts/release.sh X.Y.Z --candidate /absolute/path/to/candidate
# After exact-commit workflows pass, atomically assign the SemVer tag + publish.
./scripts/release.sh X.Y.Z --candidate /absolute/path/to/candidate --finalize
# Betas use the same prepared/staged/finalized flow, but skip device qualification.
./scripts/release.sh X.Y.Z-beta.1 --prepare /absolute/path/to/beta-candidate
./scripts/release.sh X.Y.Z-beta.1 --candidate /absolute/path/to/beta-candidate
./scripts/release.sh X.Y.Z-beta.1 --candidate /absolute/path/to/beta-candidate --finalize
```

Release mode comes from the validated SemVer tag. A version containing a
pre-release component (for example `1.1.0-beta.1`) is always marked unqualified
and published as a GitHub pre-release. A stable version cannot use
`--unqualified`; it must consume a prepared candidate and pass the complete
device and feature gates.

What `release.sh` does:

1. Verifies all eight platform slices are present in the xcframework.
2. In `--prepare` mode, strips and zips once, then records complete-tree, zip,
   both clean-build provenance records, reproducibility-proof,
   qualification-matrix, and feature-policy digests in an immutable candidate
   directory.
3. Requires physical-device qualification to name that complete post-strip
   tree and satisfy the versioned feature policy; a stable run refuses to
   rebuild, mutate, or substitute the policy bound to the candidate.
4. Verifies the prepared zip expands to the qualified XCFramework and that all
   candidate/provenance checksums still match.
5. Requires repository release immutability to be enabled, rewrites
   `Package.swift` to the intended final URL/checksum, pins the Showcase app to
   exact version `X.Y.Z`, and creates the canonical release commit. It does
   **not** create the final SemVer tag.
6. Pushes only `swiftvlc-candidate-vX.Y.Z-<full-release-SHA>`, a deliberately
   non-SemVer tag SwiftPM will not treat as a version. It creates an empty draft,
   retains exact completed uploads across retries, removes only incomplete
   `starter` uploads, uploads missing assets, rejects every conflicting asset,
   and pushes `release-candidates/vX.Y.Z` only after all assets are complete.
7. Exact-commit CI downloads that draft through authenticated `gh`, proves the
   candidate branch, non-SemVer tag, release target, checked-out SHA, intended
   final URL/checksum, and asset digest agree, then uses the verified local
   `Vendor` tree. The bridge is unavailable to pull requests, `main`, forks, and
   local consumers. A prematurely created final SemVer tag makes CI fail.
8. `--finalize` requires successful push runs for Tests, Fixtures, Vendor
   manifest, Native source contracts, and Sanitizers on that exact commit. One
   GitHub release update changes the draft to `vX.Y.Z`, targets the exact commit,
   and publishes it; there is no earlier final-tag push. Before `main` moves, the
   script verifies GitHub immutability, the signed release attestation and every
   local asset subject, an anonymous public checksum download, and a clean
   external SwiftPM consumer build. It rechecks all refs/assets, fast-forwards
   `main`, verifies the final postcondition, and removes temporary candidate refs.

Candidate preparation and first-time staging refuse non-`main` branches, any
dirty working tree, a local `main` that differs from `origin/main`, pre-existing
final release identities, disabled repository release immutability, and
unauthenticated or under-scoped `gh`. Staging is safe to pause: upload failures
and missing, pending, or failed CI leave only a non-SemVer tag plus non-public
draft and do not change `main`. Finalize classifies an uncertain publication
response before retrying anything. If publication succeeded but the subsequent
main push failed, the public immutable tag remains usable and the same command
re-verifies it before retrying only the fast-forward. Never delete, move, or
reuse a final public release tag.

After publication, verify that Swift Package Index has finished building the
tagged API reference and that the unversioned documentation link above resolves
to `1.0.0`. Its documentation build is asynchronous and may temporarily serve
the previous release while the new tag is queued.

## Architecture

For internals, including module design, C interop, the concurrency model, the event system, memory management, and the PiP rendering pipeline, see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## License

MIT. See [LICENSE](LICENSE).

libVLC is licensed under [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Static linking may have licensing implications. See the [VLC licensing FAQ](https://www.videolan.org/legal.html).

## Acknowledgments

SwiftVLC stands on the work of the [VideoLAN](https://www.videolan.org/) community. VLC and libVLC represent decades of media playback work by hundreds of contributors.

Thanks also to [VLCKit](https://code.videolan.org/videolan/VLCKit) for establishing libVLC on Apple platforms.
