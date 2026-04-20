<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-light.svg">
  <img alt="SwiftVLC" src="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-light.svg" width="260">
</picture>

A Swift wrapper around [libVLC](https://www.videolan.org/vlc/libvlc.html) for iOS, macOS, tvOS, and Mac Catalyst.

## Why?

Apple's AVFoundation covers a narrow slice of the media landscape. It cannot play MKV, FLAC, or most subtitle formats, and it does not support network protocols like RTSP, SMB, or UPnP. Codec support is limited to what Apple ships. Any app that needs to reach beyond MP4 and HLS eventually runs out of runway.

[VLC](https://www.videolan.org/) plays virtually everything, and its engine, **libVLC**, is available as a C library you can embed in any app.

The existing iOS wrapper, [VLCKit](https://code.videolan.org/videolan/VLCKit), is written in Objective-C. It uses delegates, KVO, `NSNotificationCenter`, and manual thread management, which is a faithful reflection of the era it was designed in.

**SwiftVLC** wraps libVLC 4.0 directly in Swift, with no Objective-C layer in between. It is built for `@Observable`, `async/await`, and `VideoView(player)`.

## SwiftVLC vs VLCKit

| | SwiftVLC | VLCKit |
|---|---|---|
| **Language** | Swift 6 | Objective-C |
| **Bindings** | Direct C → Swift | C → Objective-C → Swift bridging |
| **State management** | `@Observable`, drives SwiftUI directly | KVO, `NSNotificationCenter`, and delegates |
| **Concurrency** | `@MainActor`, `Sendable`, `async/await` | Manual thread dispatch, no isolation |
| **Video rendering** | `VideoView(player)` | Manual `UIView` setup plus drawable configuration |
| **Errors** | `throws(VLCError)`, typed and exhaustive | `NSError` codes |
| **Events** | `AsyncStream<PlayerEvent>` with multiple consumers | `NSNotificationCenter` |
| **libVLC version** | 4.0 | 3.x |
| **PiP** | Built in via the vmem pipeline | Not included |
| **Swift 6 safe** | Yes, with strict concurrency | No |

## Features

- `@Observable` player: state, current time, duration, tracks, and volume drive SwiftUI directly.
- `VideoView(player)` handles the rendering lifecycle in a single SwiftUI view.
- Typed errors via `throws(VLCError)` instead of error codes.
- Asynchronous media parsing: `try await media.parse()` with cancellation support.
- 10-band equalizer with libVLC's built-in presets.
- A-B looping, playback rate control, and subtitle and audio delay.
- Picture-in-Picture with full playback controls.
- Network discovery for LAN, SMB, UPnP media sources, and Chromecast and AirPlay renderers.
- 360° video with full viewpoint control over yaw, pitch, roll, and field of view.
- Asynchronous thumbnail generation at arbitrary timestamps.
- `MediaListPlayer` for playlist playback with loop and repeat modes.

## Requirements

- Swift 6.3+ / Xcode 26+
- iOS 18+ / macOS 15+ / tvOS 18+

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
.package(url: "https://github.com/harflabs/SwiftVLC.git", from: "x.y.z")
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

### Common Operations

```swift
// Playback
let player = Player()
try player.play(url: videoURL)
player.pause()
player.stop()
player.position = 0.5  // Seek to 50%
player.rate = 1.5       // 1.5x speed
player.volume = 0.8     // 80% volume
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

## Showcase App

The `Showcase/` directory contains a full-featured demo app for each supported platform:

- **iOS.** Tap-to-show controls, swipe gestures, equalizer, and PiP.
- **macOS.** Hover controls, keyboard shortcuts, and a floating settings panel.
- **tvOS.** A 10-foot UI with Siri Remote navigation and swipe-to-scrub.
- **Mac Catalyst.** The iOS player running natively on Mac.

## Testing

A comprehensive [Swift Testing](https://developer.apple.com/xcode/swift-testing/)
suite covers every public API. There is no XCTest and no mocks: every
test runs against the real libVLC binary, so regressions in the C
bridge surface immediately rather than hiding behind a fake. CI runs
the full suite on every push and every pull request.

```bash
swift test
```

See [ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy) for test tags,
fixtures, and structure.

## Development Setup

```bash
git clone https://github.com/harflabs/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
swift test
```

`setup-dev.sh` downloads `libvlc.xcframework.zip` from the latest release into `Vendor/`. `Package.swift` on every branch points at that local path, so no manifest edits are needed before building.

| `setup-dev.sh` flag | Effect |
|---|---|
| *(none)* | Download the latest release if `Vendor/` is empty; otherwise keep existing. |
| `vX.Y.Z` *(positional)* | Pin to a specific release tag. |
| `--force` | Re-download even if `Vendor/` already exists. |
| `--skip-download` | Only flip `Package.swift` to local path. Expects `Vendor/` to already exist, which is useful after running `build-libvlc.sh`. |

## Building libVLC from Source

Needed only when bumping `VLC_HASH`, modifying build patches, or preparing a release. Day-to-day Swift development doesn't require it.

```bash
brew install autoconf automake libtool cmake pkg-config gettext
./scripts/build-libvlc.sh --all
```

Expect ~15–20 minutes on a clean run and ~2–7 minutes warm on Apple Silicon. The script clones VLC at a pinned commit into `scripts/.build-libvlc/`, applies the source patches below, builds every contrib (FFmpeg, dav1d, x264, libass, …) per slice, and assembles the result into `Vendor/libvlc.xcframework`.

### Platform selection

| Flag | Platforms |
|---|---|
| *(default)* | iOS device + simulator |
| `--all` | iOS, tvOS, macOS, Mac Catalyst — six slices |
| `--ios-only` / `--tvos-only` / `--macos-only` / `--catalyst-only` | Replaces `Vendor/` with that single platform |
| `--tvos` / `--macos` / `--catalyst` | Adds a platform to the default set |
| `--clean` / `--clean-build` | Wipe `scripts/.build-libvlc/` (the latter rebuilds afterwards) |
| `--hash=<sha>` | Override the pinned VLC commit |

> `*-only` flags **replace** the xcframework; any slices already in `Vendor/` are lost.

### Source patches

VLC master doesn't build cleanly against current Xcode and Homebrew libtool. The script applies these patches in-tree on every invocation, idempotently:

1. **Mac Catalyst.** Teaches VLC's build system the `macabi` target triple and guards OpenGLES-only code paths.
2. **Xcode 26 LDFLAGS.** Adds `-isysroot` to linker invocations so libSystem resolves.
3. **libtool 2.5 OBJC tag.** Adds `_LIBTOOLFLAGS = --tag=CC` to the `Makefile.am` files that contain `.m` sources. Older libtool versions inferred the tag; 2.5 refuses.
4. **Rust contribs disabled.** `cargo-c 0.9.29` no longer compiles on recent Rust. The only Rust contrib on Apple is `rav1e` (AV1 *encoder*); `dav1d` handles decoding.
5. **`dup3` / `pipe2`.** Forced unavailable via autoconf cache vars. iOS Simulator SDK 26 exports these Linux-only syscalls from libSystem, fooling configure into using them.

`git reset --hard` only runs when HEAD is not at `VLC_HASH`, so the patches and per-platform build dirs survive repeated runs.

## Releasing

Releases use a **tag-only** model: the commit that pins `Package.swift` to the remote xcframework URL exists only under the tag, never on a branch. Every branch stays ready for `setup-dev.sh && swift build`.

```bash
./scripts/build-libvlc.sh --all          # produces Vendor/libvlc.xcframework
./scripts/release.sh X.Y.Z --dry-run     # strip + zip + checksum, no push
./scripts/release.sh X.Y.Z               # cut the release
```

What `release.sh` does:

1. Verifies all six platform slices are present in the xcframework.
2. Copies it to a temp dir, strips debug symbols, zips with `ditto`.
3. Computes SHA-256 via `swift package compute-checksum`.
4. Creates a detached commit with `Package.swift` rewritten to the remote URL and checksum.
5. Tags that commit as `vX.Y.Z`.
6. Resets the branch back to its previous HEAD; the commit survives only as the tag.
7. Pushes the tag (never the branch).
8. Uploads the zip to a new GitHub Release.

Preflight refuses non-`main` branches (`--allow-dirty-branch` to override), pre-existing local tags, and unauthenticated `gh`. If any later step fails, the EXIT trap resets the branch to its pre-release HEAD so nothing is left dangling.

## Architecture

For internals, including module design, C interop, the concurrency model, the event system, memory management, and the PiP rendering pipeline, see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## License

MIT. See [LICENSE](LICENSE).

libVLC is licensed under [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Static linking may have licensing implications. See the [VLC licensing FAQ](https://www.videolan.org/legal.html).

## Acknowledgments

SwiftVLC stands on the work of the [VideoLAN](https://www.videolan.org/) community. The VLC media player and libVLC are among the most important open-source projects in media, representing decades of work by hundreds of contributors that made it possible to play virtually anything, anywhere.

Thanks also to [VLCKit](https://code.videolan.org/videolan/VLCKit) for paving the way for libVLC on Apple platforms. VLCKit proved that embedding VLC in iOS and macOS apps was not only possible but practical, and it has powered countless apps over the years. SwiftVLC would not exist without the foundation VLCKit laid.
