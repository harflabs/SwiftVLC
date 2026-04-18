<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/logo-light.svg">
  <img alt="SwiftVLC" src="Assets/logo-light.svg" width="260">
</picture>

A modern Swift wrapper around [libVLC](https://www.videolan.org/vlc/libvlc.html) for iOS, macOS, tvOS, and Mac Catalyst.

## Why?

Apple's AVFoundation is great until it isn't. It can't play MKV, FLAC, or most subtitle formats. It doesn't support network streams like RTSP, SMB, or UPnP. Codec support is limited to what Apple ships. If your app needs to play anything beyond MP4/HLS, you hit a wall.

[VLC](https://www.videolan.org/) solves this — it plays virtually everything. And its engine, **libVLC**, is available as a C library that can be embedded in any app.

The existing iOS wrapper, [VLCKit](https://code.videolan.org/videolan/VLCKit), is Objective-C. It uses delegates, KVO, `NSNotificationCenter`, and manual thread management. It was designed before Swift existed and it shows.

**SwiftVLC** wraps libVLC 4.0 directly in Swift — no Objective-C layer in between. It's built for `@Observable`, `async/await`, and `VideoView(player)`.

## SwiftVLC vs VLCKit

| | SwiftVLC | VLCKit |
|---|---|---|
| **Language** | Swift 6 | Objective-C |
| **Bindings** | Direct C → Swift | C → Objective-C → Swift bridging |
| **State management** | `@Observable` — automatic SwiftUI updates | KVO / `NSNotificationCenter` / delegates |
| **Concurrency** | `@MainActor`, `Sendable`, `async/await` | Manual thread dispatch, no isolation |
| **Video rendering** | `VideoView(player)` — one line | Manual `UIView` setup + drawable configuration |
| **Errors** | `throws(VLCError)` — typed, exhaustive | `NSError` codes |
| **Events** | `AsyncStream<PlayerEvent>` — multi-consumer | `NSNotificationCenter` |
| **libVLC version** | 4.0 | 3.x |
| **PiP** | Built-in via vmem pipeline | Not included |
| **Swift 6 safe** | Yes — strict concurrency, all types `Sendable` | No |

## Features

- **`@Observable` Player** — state, time, duration, tracks, volume all drive SwiftUI automatically
- **One-line video** — `VideoView(player)` handles the entire rendering lifecycle
- **Typed errors** — `throws(VLCError)` instead of error codes
- **Async media parsing** — `try await media.parse()` with cancellation support
- **10-band equalizer** with 25 built-in presets
- **A-B looping**, playback rate control, subtitle/audio delay
- **Picture-in-Picture** with full playback controls
- **Network discovery** — LAN, SMB, UPnP media and Chromecast/AirPlay renderers
- **360° video** — viewpoint control (yaw, pitch, roll, FOV)
- **Thumbnails** — async generation at any timestamp
- **Playlist** — `MediaListPlayer` with loop/repeat modes

## Requirements

- Swift 6.3+ / Xcode 26+
- iOS 18+ / macOS 15+ / tvOS 18+

## Installation

Add SwiftVLC as a Swift Package dependency:

```swift
.package(url: "https://github.com/harflabs/SwiftVLC.git", from: "0.1.0")
```

Or in Xcode: **File > Add Package Dependencies** and enter the URL above.

The pre-built libVLC xcframework (~1.2 GB) downloads automatically via SPM.

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

The `Showcase/` directory contains a full-featured demo app for all supported platforms:

- **iOS** — Tap-to-show controls, swipe gestures, equalizer, PiP
- **macOS** — Hover controls, keyboard shortcuts, floating settings panel
- **tvOS** — 10-foot UI with Siri Remote, swipe-to-scrub
- **Mac Catalyst** — iOS player running natively on Mac

## Testing

758 tests across 61 suites using [Swift Testing](https://developer.apple.com/xcode/swift-testing/) — real libVLC integration, no mocking.

```bash
swift test
```

See [ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy) for test tags, fixtures, and structure.

## Building libVLC from Source

The xcframework downloads automatically via SPM. To rebuild from the [official VLC source](https://code.videolan.org/videolan/vlc):

```bash
brew install autoconf automake libtool

./scripts/build-libvlc.sh          # iOS (default)
./scripts/build-libvlc.sh --all    # All platforms
```

~15 minutes per platform on Apple Silicon.

## Development Setup

```bash
git clone https://github.com/harflabs/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
swift test
```

The setup script downloads the xcframework and switches `Package.swift` to a local path.

## Architecture

For internals — module design, C interop, concurrency model, event system, memory management, and the PiP rendering pipeline — see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## License

MIT License — see [LICENSE](LICENSE).

libVLC is licensed under [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Static linking may have licensing implications. See the [VLC licensing FAQ](https://www.videolan.org/legal.html).

## Acknowledgments

SwiftVLC is built on the incredible work of the [VideoLAN](https://www.videolan.org/) community. The VLC media player and libVLC are among the most important open-source projects in media — decades of work by hundreds of contributors making it possible to play virtually anything, anywhere.

Special thanks to [VLCKit](https://code.videolan.org/videolan/VLCKit) for paving the way for libVLC on Apple platforms. VLCKit proved that embedding VLC in iOS and macOS apps was not only possible but practical, and it has powered countless apps over the years. SwiftVLC wouldn't exist without the foundation VLCKit laid.
