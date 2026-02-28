# SwiftVLC

A modern Swift wrapper around [libVLC](https://www.videolan.org/vlc/libvlc.html) for iOS, macOS, tvOS, and Mac Catalyst.

SwiftVLC provides a Swift-first API for media playback using the same engine that powers the VLC media player. It wraps the libVLC 4.0 C library directly — no Objective-C layer, no VLCKit dependency.

## Why SwiftVLC?

VLCKit is Objective-C, callback-heavy, and requires manual thread management. SwiftVLC was built to bring libVLC into modern Swift:

- **`@Observable`** — Player state drives SwiftUI views automatically. No delegates, no Combine publishers, no manual invalidation.
- **Swift 6 concurrency** — `@MainActor` isolation, `Sendable` types, `async/await` for media parsing.
- **One-line video** — `VideoView(player)` handles the entire rendering lifecycle.
- **Typed errors** — `throws(VLCError)` instead of NSError codes.
- **Full libVLC feature set** — Equalizer, A-B loop, media discovery, renderer discovery, PiP, 360° viewpoint, thumbnails, and more.

## Requirements

- Swift 6.2+ / Xcode 16+
- iOS 18+ / macOS 15+ / tvOS 18+
- The pre-built `libvlc.xcframework` in `Vendor/` (or build it yourself — see below)

## Installation

Add SwiftVLC as a Swift Package dependency:

```swift
.package(url: "https://github.com/harflabs/SwiftVLC.git", from: "0.1.0")
```

Or add it in Xcode via **File > Add Package Dependencies** and enter the URL above.

The pre-built libVLC xcframework downloads automatically when SPM resolves the package — no manual setup needed.

## Quick Start

```swift
import SwiftUI
import SwiftVLC

struct PlayerView: View {
    @State private var player = Player()

    var body: some View {
        VideoView(player)
            .onAppear {
                let media = Media(url: URL(string: "https://example.com/video.mp4")!)
                player.setMedia(media)
                player.play()
            }
    }
}
```

### Common Operations

```swift
// Playback control
player.play()
player.pause()
player.stop()
player.position = 0.5       // Seek to 50%
player.rate = 1.5            // 1.5x speed
player.volume = 0.8          // 80% volume
player.isMuted = true

// Track selection
let subtitles = player.subtitleTracks
player.selectTrack(subtitles[1])

// Metadata
let media = Media(url: videoURL)
let metadata = try await media.parse()
print(metadata.title, metadata.duration)

// Observe state changes
for await event in player.events() {
    switch event {
    case .stateChanged(let state): ...
    case .timeChanged(let time): ...
    case .endReached: ...
    default: break
    }
}
```

## Project Structure

```
SwiftVLC/
├── Package.swift
├── Sources/
│   ├── SwiftVLC/           # Swift wrapper
│   │   ├── Core/           # VLCInstance, VLCError, Logging
│   │   ├── Player/         # Player, PlayerState, PlayerEvent
│   │   ├── Media/          # Media, Track, Metadata
│   │   ├── Video/          # VideoView, AspectRatio, VideoAdjustments
│   │   ├── Audio/          # AudioOutput, Equalizer
│   │   ├── Playlist/       # MediaListPlayer, PlaybackMode
│   │   ├── Discovery/      # MediaDiscoverer, RendererDiscoverer
│   │   └── PiP/            # Picture-in-Picture
│   └── CLibVLC/            # C bridging shim + libVLC headers
├── Vendor/
│   └── libvlc.xcframework  # Pre-built libVLC static library
├── Demo/                    # Multi-platform demo app
└── build-libvlc.sh         # Script to compile libVLC from source
```

## Building libVLC from Source

The `Vendor/libvlc.xcframework` is a pre-built static library. To rebuild it from the official VLC source:

### Prerequisites

```bash
brew install autoconf automake libtool
```

### Build Commands

```bash
# iOS device + simulator (default)
./build-libvlc.sh

# All platforms
./build-libvlc.sh --all

# Individual platforms
./build-libvlc.sh --ios-only
./build-libvlc.sh --macos-only
./build-libvlc.sh --tvos-only
./build-libvlc.sh --catalyst-only

# Combine flags
./build-libvlc.sh --ios-only --macos --catalyst
```

The script clones the official VLC repository, compiles libVLC as a static library for each architecture, and packages everything into an xcframework. Mac Catalyst builds are automatically patched to handle OpenGLES unavailability.

Build times vary: ~15 minutes per platform on Apple Silicon.

## Demo App

The `Demo/` directory contains a full-featured video player app that runs on all supported platforms. Open `Demo/SwiftVLCDemo.xcodeproj` in Xcode.

Each platform has its own player UI tailored to the input method:

- **iOS** — Full-screen player with tap-to-show overlay controls, double-tap to skip, swipe gestures, settings sheet with equalizer/video adjustments/playlist, PiP support.
- **macOS** — Desktop player with hover controls, keyboard shortcuts (space, arrows, M, F, brackets for speed), right-click context menu, floating settings panel.
- **tvOS** — 10-foot UI with Siri Remote navigation, swipe-to-scrub, click for play/pause, swipe-down info panel with focusable buttons (no sliders).
- **Mac Catalyst** — Runs the iOS player on Mac via Catalyst.

## Testing

SwiftVLC includes 397 tests across 32 suites using the [Swift Testing](https://developer.apple.com/xcode/swift-testing/) framework. Tests cover all non-UI source files with real libVLC integration (no mocking).

### Run All Tests

```bash
swift test
```

### Filter by Tag

Tests are tagged for selective execution:

| Tag | Description |
|---|---|
| `logic` | Pure Swift logic — no libVLC needed |
| `integration` | Requires a real libVLC instance |
| `media` | Requires bundled media fixtures |
| `mainActor` | Runs on `@MainActor` |
| `async` | Async tests |

```bash
# Fast logic-only tests (no media or libVLC dependencies)
swift test --filter "logic"

# Run a specific suite
swift test --filter "PlayerTests"
swift test --filter "EqualizerTests"
```

### Test Structure

```
Tests/SwiftVLCTests/
├── Support/           # TestMedia (fixture URLs), Tags
├── Fixtures/          # Bundled test media (~50KB)
│   ├── test.mp4       # 1s 64x64 video with metadata
│   ├── twosec.mp4     # 2s video for seeking/duration tests
│   ├── silence.wav    # Silent audio
│   └── test.srt       # Minimal subtitle file
├── Core/              # VLCInstance, VLCError, Logging, Duration, DialogHandler
├── Player/            # Player, PlayerState, PlayerEvent, EventBridge, etc.
├── Media/             # Media, Track, Metadata, Statistics, Thumbnail
├── Audio/             # Equalizer, AudioOutput, AudioChannelMode
├── Video/             # AspectRatio, Viewpoint, VideoAdjustments, Marquee, Logo
├── Playlist/          # MediaList, MediaListPlayer, PlaybackMode
└── Discovery/         # MediaDiscoverer, RendererDiscoverer
```

## Development Setup

To contribute or build locally, clone the repo and run the setup script to download the xcframework:

```bash
git clone https://github.com/harflabs/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
swift test
```

The setup script downloads the pre-built xcframework from the latest GitHub Release and switches `Package.swift` to use a local path for development.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file.

**Note:** libVLC itself is licensed under the [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Static linking of libVLC may have licensing implications for your project. See the [VLC licensing FAQ](https://www.videolan.org/legal.html) for details.
