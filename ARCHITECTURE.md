# Architecture

Technical decisions and design rationale for SwiftVLC, written for
contributors and reviewers.

> Looking for **how to use** SwiftVLC? See the DocC guides (published on
> Swift Package Index) or run `swift package preview-documentation
> --target SwiftVLC` locally. This document covers the *why* behind the
> design: build/release infrastructure, C-interop patterns, isolation
> choices, deinit ordering, and the testing strategy.

## Contents

- [High-Level Overview](#high-level-overview)
- [Tech Stack](#tech-stack)
- [Module Architecture](#module-architecture)
- [C Interop Layer](#c-interop-layer)
- [Concurrency & Threading Model](#concurrency--threading-model)
- [Event System](#event-system)
- [Memory Management](#memory-management)
- [Video Rendering](#video-rendering)
- [Picture-in-Picture](#picture-in-picture)
- [Error Handling](#error-handling)
- [Testing Strategy](#testing-strategy)
- [Build & Release Infrastructure](#build--release-infrastructure)
- [Project Structure](#project-structure)

---

## High-Level Overview

```mermaid
flowchart TB
    subgraph App["SwiftUI App"]
        VV["VideoView(player)"]
        PS["player.state"]
        PV["player.volume"]
    end

    subgraph SwiftVLC["SwiftVLC Library"]
        direction TB
        subgraph Top["Primary Modules"]
            Player["Player<br/>@Observable · @MainActor"]
            Media["Media<br/>Sendable · async"]
            Audio["Audio<br/>EQ · Modes"]
            Video["Video<br/>VideoView · Adjustments"]
        end
        subgraph Bottom["Supporting Modules"]
            Playlist["Playlist<br/>MediaList · ListPlayer"]
            Discovery["Discovery<br/>LAN/UPnP · Renderer"]
            PiP["PiP<br/>vmem → PiP API"]
            EventBridge["EventBridge<br/>C → AsyncStream"]
        end
    end

    subgraph CLibVLC["CLibVLC"]
        Shim["C shim + libVLC 4.0 headers"]
    end

    subgraph XCF["libvlc.xcframework"]
        Binary["Pre-built libVLC 4.0<br/>iOS · macOS · tvOS · visionOS · Catalyst<br/>21 system frameworks · 7 system libraries"]
    end

    App --> SwiftVLC
    Top --> Bottom
    SwiftVLC --> CLibVLC
    CLibVLC --> XCF
```

**Key concepts:**

- **Swift-first**: Direct C → Swift bindings, no Objective-C intermediary (unlike VLCKit)
- **Observable state**: `@Observable` `@MainActor` Player drives SwiftUI updates automatically
- **Typed concurrency**: Swift 6 strict concurrency. Every public type is `Sendable`, and async APIs use `AsyncStream`.
- **One-liner rendering**: `VideoView(player)` covers the setup, delegate wiring, and callbacks in one call.
- **Typed errors**: `throws(VLCError)` for compile-time error handling

---

## Tech Stack

| Component | Choice | Why |
|---|---|---|
| **Language** | Swift 6.3+ | Strict concurrency, typed throws, `@Observable`, upcoming feature flags |
| **C Bindings** | libVLC 4.0 C API | Direct access, no Objective-C overhead |
| **State** | `@Observable` / `@MainActor` | Automatic SwiftUI integration, thread safety |
| **Events** | `AsyncStream<PlayerEvent>` | Native structured concurrency, multi-consumer |
| **Video** | `UIView` / `NSView` via `set_nsobject` | Platform-native rendering, zero-copy |
| **PiP** | vmem → `CVPixelBuffer` → `AVSampleBufferDisplayLayer` | Full pixel control for PiP API |
| **Thread Safety** | `Mutex<T>`, `Sendable`, `nonisolated(unsafe)` | Compile-time data race prevention |
| **Testing** | Swift Testing framework | Modern `@Test`, `#expect`, tags, traits |
| **Platforms** | iOS 18+, macOS 15+, tvOS 18+, visionOS 2+, Mac Catalyst | Unified SwiftUI minimum |

---

## Module Architecture

### Core

Foundation types shared across all modules.

| File | Type | Purpose |
|---|---|---|
| `VLCInstance.swift` | `final class VLCInstance: Sendable` | Manages `libvlc_instance_t*` lifecycle. Singleton `shared` or custom with arguments. |
| `VLCError.swift` | `enum VLCError: Error, Sendable` | Typed errors: `instanceCreationFailed`, `mediaCreationFailed`, `playbackFailed`, `parseFailed`, `parseTimeout`, `trackNotFound`, `invalidState`, `operationFailed` |
| `Logging.swift` | `AsyncStream<LogEntry>` | Filterable log stream (debug/notice/warning/error). C shim formats `va_list` before Swift callback. |
| `Duration+Extensions.swift` | Extensions on `Duration` | `milliseconds`, `microseconds` properties and `formatted` display string |

**Default VLC arguments:** `["--no-video-title-show", "--no-snapshot-preview"]`. `--no-stats` is *not* in the defaults — leaving it on would silently zero every `Media.statistics()` read, which is almost never what a caller wants.

### Player

The central observable type that drives all playback.

| File | Type | Purpose |
|---|---|---|
| `Player.swift` | `@Observable @MainActor class` | Wraps `libvlc_media_player_t*`. All playback control, state, and track management. |
| `EventBridge.swift` | `internal class` | C callbacks → `AsyncStream<PlayerEvent>` multi-consumer broadcaster |
| `PlayerState.swift` | `enum PlayerState` | `.idle`, `.opening`, `.buffering`, `.playing`, `.paused`, `.stopped`, `.stopping`, `.error`. Buffer fill is exposed separately as `Player.bufferFill` so `.paused` players still publish progress. |
| `PlayerEvent.swift` | `enum PlayerEvent` | Typed Swift cases mapped from libVLC's player event types |
| `PlayerRole.swift` | `enum PlayerRole` | Audio behavior hints: `.music`, `.video`, `.communication`, `.game`, etc. |
| `ABLoop.swift` | `enum ABLoopState` | `.none` → `.pointASet` → `.active` |
| `NavigationAction.swift` | `enum NavigationAction` | DVD/Blu-ray menu: `.activate`, `.up`, `.down`, `.left`, `.right`, `.popup` |
| `Program.swift` | `struct Program` | DVB/MPEG-TS program: id, name, isSelected, isScrambled |

**Player API surface:**

```swift
// Observable properties (auto-update SwiftUI)
player.state              // PlayerState
player.currentTime        // Duration
player.duration           // Duration?
player.isSeekable         // Bool
player.isPausable         // Bool
player.currentMedia       // Media?
player.audioTracks        // [Track]
player.videoTracks        // [Track]
player.subtitleTracks     // [Track]

// Bindable properties (two-way binding)
player.position           // Double (0.0–1.0), seeks on set
player.volume             // Float (0.0–1.25)
player.isMuted            // Bool
player.rate               // Float (0.25–4.0)
player.selectedAudioTrack // Track?
player.selectedSubtitleTrack // Track?
player.aspectRatio        // AspectRatio
player.audioDelay         // Duration
player.subtitleDelay      // Duration
player.subtitleTextScale  // Float

// Playback control
try player.play(url: someURL)
player.pause()
player.resume()
player.seek(to: .seconds(30))
player.seek(by: .seconds(-10))
player.stop()

// Advanced
player.setABLoop(a: .seconds(10), b: .seconds(20))
player.takeSnapshot(to: path, width: 320, height: 240)
player.startRecording(to: directoryPath)
player.updateViewpoint(Viewpoint(yaw: 90, pitch: 0, roll: 0, fieldOfView: 80))
```

### Media

Media resource creation, parsing, and metadata.

| File | Type | Purpose |
|---|---|---|
| `Media.swift` | `final class Media: Sendable` | Wraps `libvlc_media_t*`. Create from URL, path, or file descriptor. Async parsing with cancellation. |
| `Metadata.swift` | `struct Metadata: Sendable` | libVLC's metadata keys surfaced as typed properties (title, artist, album, duration, artworkURL, genre, …) |
| `Track.swift` | `struct Track: Sendable` | Audio/video/subtitle track info with type-specific fields (channels, resolution, encoding) |
| `ThumbnailRequest.swift` | Extension on `Media` | `thumbnail(at:width:height:crop:timeout:) async throws → Data` |
| `MediaStatistics.swift` | `struct MediaStatistics: Sendable` | Runtime stats: decoded/displayed/lost frames, bitrates, buffer counts |

**Parsing flow:**

```mermaid
sequenceDiagram
    participant App
    participant Media
    participant libVLC

    App->>Media: parse(timeout:) async throws
    Media->>libVLC: libvlc_media_parse_request()
    libVLC-->>Media: MediaParsedChanged event
    alt Task cancelled
        Media->>libVLC: libvlc_media_parse_stop()
    else Timeout exceeded
        Media-->>App: throws .parseTimeout
    else Success
        Media-->>App: returns Metadata
    end
```

### Audio

Audio output, equalization, and channel configuration.

| File | Type | Purpose |
|---|---|---|
| `AudioOutput.swift` | `struct AudioOutput`, `struct AudioDevice` | Available output modules and devices. Extensions on `VLCInstance` and `Player`. |
| `Equalizer.swift` | `@Observable @MainActor class Equalizer` | 10-band EQ with preamp (-20 to +20 dB). libVLC's built-in presets. Attach via `player.equalizer`; mutations re-apply automatically. |
| `AudioChannelMode.swift` | `enum StereoMode`, `enum MixMode` | Stereo/mono/Dolby, 4.0/5.1/7.1/binaural mixing |

### Video

Video rendering, overlays, and adjustments.

| File | Type | Purpose |
|---|---|---|
| `VideoView.swift` | SwiftUI `UIViewRepresentable` / `NSViewRepresentable` | One-liner: `VideoView(player)`. Platform-specific `VideoSurface` underneath. |
| `AspectRatio.swift` | `enum AspectRatio` | `.default`, `.ratio(w, h)`, `.fill` |
| `VideoAdjustments.swift` | `@MainActor struct VideoAdjustments` | brightness, contrast, hue, saturation, gamma — accessed via `player.adjustments` |
| `Marquee.swift` | `@MainActor struct Marquee` | Scrolling text overlay: text, color, opacity, position, timeout |
| `Logo.swift` | `@MainActor struct Logo` | Image overlay: file path, position, opacity, animation |
| `Viewpoint.swift` | `struct Viewpoint: Sendable` | 360° video: yaw, pitch, roll, fieldOfView (degrees) |

### Playlist

Playlist management and sequential/looped playback.

| File | Type | Purpose |
|---|---|---|
| `MediaList.swift` | `final class MediaList: Sendable` | Thread-safe list wrapping `libvlc_media_list_t*`. Append/insert/remove with internal locking. |
| `MediaListPlayer.swift` | `@MainActor class MediaListPlayer` | Sequential playback with `play(at:)`, `next()`, `previous()` |
| `PlaybackMode.swift` | `enum PlaybackMode` | `.default`, `.loop`, `.repeat` |

### Discovery

Network service and renderer discovery.

| File | Type | Purpose |
|---|---|---|
| `MediaDiscoverer.swift` | `final class MediaDiscoverer: Sendable` | Discovers media on LAN/SMB/UPnP/SAP. Returns `MediaList` of found items. |
| `RendererDiscoverer.swift` | `final class RendererDiscoverer: Sendable` | Discovers Chromecast/AirPlay renderers. `AsyncStream<RendererEvent>` for add/remove. |

### PiP (iOS/macOS only)

Picture-in-Picture via video memory callbacks.

| File | Type | Purpose |
|---|---|---|
| `PiPController.swift` | `@MainActor class PiPController` | Manages `AVPictureInPictureController` lifecycle, timebase sync, playback delegation |
| `PiPVideoView.swift` | SwiftUI representable | `PiPVideoView(player, controller: $binding)` — hosts the sample buffer display layer |
| `PixelBufferRenderer.swift` | `class PixelBufferRenderer: Sendable` | vmem callbacks: format → lock → unlock → display. `CVPixelBufferPool` → `CMSampleBuffer` → layer. |

---

## C Interop Layer

### CLibVLC Target

```
Sources/CLibVLC/
├── include/vlc/          # Full libVLC 4.0 C headers
│   ├── vlc.h             # Main umbrella header
│   ├── libvlc.h          # Instance, logging, dialogs
│   ├── libvlc_media.h    # Media creation, parsing, metadata
│   ├── libvlc_media_player.h  # Player, tracks, events
│   ├── libvlc_media_list.h    # Playlist
│   ├── libvlc_media_discoverer.h  # Network discovery
│   ├── libvlc_renderer_discoverer.h  # Chromecast/AirPlay
│   ├── libvlc_picture.h  # Thumbnail generation
│   └── libvlc_events.h   # Event types
└── shim.c                # C shim for va_list formatting
```

### Why a C Shim?

Swift cannot directly consume C variadic functions (`va_list`). The shim provides:

```c
// shim.c — formats va_list into a fixed buffer before calling Swift
void swiftvlc_log_set(libvlc_instance_t *instance, void *opaque,
                       swiftvlc_log_cb callback);
```

This allows the logging callback to receive a pre-formatted `const char *` instead of a `va_list`.

### Linked Frameworks & Libraries

The xcframework links against the system frameworks and libraries
libVLC needs for decoding, rendering, and platform services:

**Frameworks:** AudioToolbox, AudioUnit\*, AVFoundation, AVKit, CoreAudio, CoreFoundation, CoreGraphics, CoreImage, CoreMedia, CoreServices, CoreText, CoreVideo, Foundation, IOKit\*, IOSurface, OpenGL\*, OpenGLES\*, QuartzCore, Security, SystemConfiguration, VideoToolbox

**Libraries:** libbz2, libc++, libiconv, libresolv, libsqlite3, libxml2, libz

\*Platform-conditional: AudioUnit/IOKit/OpenGL are macOS-only; OpenGLES is iOS/tvOS/visionOS-only.

---

## Concurrency & Threading Model

### Isolation Strategy

```mermaid
flowchart LR
    subgraph MainActor["@MainActor — mutable state, SwiftUI"]
        MA["Player · MediaListPlayer · Equalizer<br/>VideoAdjustments · Marquee · Logo<br/>PiPController · SwiftUI Views"]
    end

    subgraph VLCThreads["libVLC internal threads"]
        VLC["Event callbacks · Logging<br/>Decode (vmem)"]
    end

    subgraph Sendable["Sendable — any isolation"]
        S["VLCInstance · Media · MediaList<br/>Track · Metadata · MediaStatistics<br/>PixelBufferRenderer · VLCError · all enums"]
    end

    VLCThreads -->|"AsyncStream yield"| MainActor
    Sendable -.->|"safe to pass"| MainActor
    Sendable -.->|"safe to pass"| VLCThreads
```

**Rules:**

1. **`@MainActor` types** own mutable state that SwiftUI observes. All property access and mutation happens on the main actor.
2. **`Sendable` types** are either immutable value types or use internal synchronization (`Mutex<T>`, libVLC's own locks).
3. **C callbacks** fire on libVLC's internal threads. They yield values into `AsyncStream` continuations (which are thread-safe) or dispatch to main via `DispatchQueue.main.async`.
4. **`nonisolated(unsafe)`** is used for `OpaquePointer` fields that are only valid during the object's lifetime and accessed on the correct actor.

### Capturing C Pointers in `@Sendable` Closures

`OpaquePointer` and `UnsafeMutableRawPointer` aren't `Sendable` under Swift's region-based isolation, so getting them into `@Sendable` closures (`withTaskCancellationHandler` `onCancel`, `DispatchQueue.*.async`) needs one of two mechanisms:

- **`nonisolated(unsafe) let` local binding**, for captures into a single closure. The local opts out of isolation checking; the pointer is trivially transferable and stays valid for the enclosing scope. Used in `Media.parse`, `Player.deinit`, `MediaListPlayer.deinit`, `PixelBufferRenderer`, and the deinits in `DialogHandler`, `RendererDiscoverer`, and `MediaDiscoverer`.
  ```swift
  nonisolated(unsafe) let p = pointer
  DispatchQueue.global(qos: .utility).async {
    libvlc_media_player_release(p)
  }
  ```

- **`Mutex<State>` with `State: @unchecked Sendable`**, for persistent storage of pointers that must be read or written from multiple threads. `Mutex`'s `sending` semantics require `State` to be sendable to the callee; marking `State: @unchecked Sendable` honors that while the `Mutex` itself provides the actual mutual exclusion. Used by `LogBroadcaster`, `ThumbnailRequest.RequestBox`, and `PixelBufferRenderer`.
  ```swift
  private struct State: @unchecked Sendable {
    var selfBox: UnsafeMutableRawPointer?
  }
  private let state = Mutex(State())
  ```

Never use `Int(bitPattern:)` round-trips to launder pointers through `Sendable`. It loses type information and obscures intent.

---

## Event System

Three-layer architecture bridging C callbacks to SwiftUI:

```mermaid
flowchart TB
    subgraph L1["C Callbacks — libVLC thread"]
        CB["Player event types attached via libvlc_event_attach<br/>playerEventCallback → mapEvent()"]
    end

    subgraph L2["AsyncStream Broadcasting — any thread"]
        Store["EventBridge · Mutex-protected continuation store<br/>Each makeStream() creates an independent consumer"]
    end

    subgraph L3["Observable Properties — @MainActor"]
        Update["Player event consumer Task<br/>for await event → update @Observable props"]
    end

    CB -->|"yield to all continuations"| Store
    Store -->|"consumed by"| Update
```

### PlayerEvent Cases

libVLC's player event types are attached to the event manager and mapped to typed Swift cases:

| Category | Swift Cases |
|---|---|
| **State** | `stateChanged(PlayerState)`, `encounteredError` |
| **Time** | `timeChanged(Duration)`, `positionChanged(Double)`, `lengthChanged(Duration)` |
| **Capability** | `seekableChanged(Bool)`, `pausableChanged(Bool)` |
| **Tracks** | `tracksChanged`, `mediaChanged` |
| **Buffering** | `bufferingProgress(Float)` |
| **Audio** | `volumeChanged(Float)`, `muted`, `unmuted` |
| **Video** | `voutChanged(Int)`, `snapshotTaken(String)` |
| **Chapters** | `chapterChanged(Int)`, `titleListChanged`, `titleSelectionChanged(Int)` |
| **Recording** | `recordingChanged(isRecording:filePath:)` |
| **Programs** | `programAdded(Int)`, `programDeleted(Int)`, `programSelected(unselectedId:selectedId:)`, `programUpdated(Int)` |

### Multi-Consumer Broadcasting

Id allocation and dictionary updates live under a single `Mutex<State>`, so registration is one lock acquisition. `broadcast` snapshots the continuations under the lock and yields outside it. Yielding resumes a consumer task and acquires its status-record lock; a concurrent task cancellation holds that same lock and calls `onTermination → remove → acquire Mutex`, so yielding while holding the `Mutex` would produce an AB-BA deadlock.

```swift
private final class ContinuationStore: Sendable {
  private struct State {
    var nextID: Int = 0
    var continuations: [Int: AsyncStream<PlayerEvent>.Continuation] = [:]
  }
  private let state = Mutex(State())

  func add(continuation: AsyncStream<PlayerEvent>.Continuation) -> Int {
    state.withLock { state in
      let id = state.nextID
      state.nextID += 1
      state.continuations[id] = continuation
      return id
    }
  }

  func broadcast(_ event: PlayerEvent) {
    let snapshot = state.withLock { Array($0.continuations.values) }
    for cont in snapshot { cont.yield(event) }  // yield outside the lock
  }
}
```

### Lifecycle

1. **`Player.init()`** creates the `EventBridge` and attaches every event type to the libVLC event manager.
2. **`startEventConsumer()`** spawns a `Task` that reads the bridge stream and updates the player's `@Observable` properties.
3. **`Player.deinit`** cancels the consumer task, then calls `EventBridge.invalidate()` to detach the C callbacks, finish the continuations, and release the store.

---

## Memory Management

### OpaquePointer Lifecycle

Every libVLC object follows the same pattern: **`init` allocates → use passes pointer → `deinit` releases**. Swift object lifetime owns C pointer lifetime.

| Swift Type | C Pointer | Alloc | Free |
|---|---|---|---|
| `VLCInstance` | `libvlc_instance_t*` | `libvlc_new` | `libvlc_release` |
| `Player` | `libvlc_media_player_t*` | `libvlc_media_player_new` | `libvlc_media_player_release` |
| `Media` | `libvlc_media_t*` | `libvlc_media_new_*` | `libvlc_media_release` |
| `MediaList` | `libvlc_media_list_t*` | `libvlc_media_list_new` | `libvlc_media_list_release` |
| `MediaListPlayer` | `libvlc_media_list_player_t*` | `libvlc_media_list_player_new` | `libvlc_media_list_player_release` |
| `MediaDiscoverer` | `libvlc_media_discoverer_t*` | `libvlc_media_discoverer_new` | `libvlc_media_discoverer_release` |
| `RendererDiscoverer` | `libvlc_renderer_discoverer_t*` | `libvlc_renderer_discoverer_new` | `libvlc_renderer_discoverer_release` |
| `RendererItem` | `libvlc_renderer_item_t*` | `libvlc_renderer_item_hold` | `libvlc_renderer_item_release` |
| `Equalizer` | `libvlc_equalizer_t*` | `libvlc_audio_equalizer_new` | `libvlc_audio_equalizer_release` |

### Unmanaged Patterns

For C callback contexts that need to bridge to Swift objects:

| Pattern | Use Case | Lifetime |
|---|---|---|
| `Unmanaged.passRetained` | Long-lived callback context (EventBridge store, LogContext, DialogHandler) | Explicitly released in cleanup/deinit |
| `Unmanaged.passUnretained` | Short-lived reference (VideoSurface in `set_nsobject`) | Object must outlive the call |

### Deinit Ordering

Ordering in `Player.deinit` is load-bearing: detaching the listeners **before** releasing the player prevents use-after-free when a callback fires during teardown.

1. Cancel event consumer task
2. `EventBridge.invalidate()`
   - Detach all 31 C event listeners
   - Finish all `AsyncStream` continuations
   - Release retained store
3. `libvlc_media_player_stop_async()`
4. `libvlc_media_player_release()`

---

## Video Rendering

### VideoView Architecture

```mermaid
sequenceDiagram
    participant SwiftUI
    participant VideoView
    participant VideoSurface as VideoSurface<br/>(UIView / NSView)
    participant libVLC

    SwiftUI->>VideoView: makeUIView / makeNSView
    VideoView->>VideoSurface: create
    VideoSurface->>libVLC: set_nsobject(view pointer)
    libVLC->>VideoSurface: adds rendering sublayer
    loop On resize
        VideoSurface->>VideoSurface: layoutSubviews() — sync sublayer frames
    end
    SwiftUI->>VideoView: dismantleUIView
    VideoSurface->>libVLC: set_nsobject(nil)
```

There is no `CALayer` setup, no `MTKView`, and no `AVPlayerLayer` to configure. libVLC handles all rendering internally.

---

## Picture-in-Picture

PiP uses a fundamentally different rendering path than `VideoView`:

| Path | Pipeline |
|---|---|
| **VideoView** | `set_nsobject` → VLC renders directly into the view |
| **PiP** | vmem callbacks → `CVPixelBuffer` → `CMSampleBuffer` → `AVSampleBufferDisplayLayer` → PiP |

### vmem Callback Pipeline

```mermaid
flowchart TB
    subgraph PBR["PixelBufferRenderer — Mutex&lt;State&gt;"]
        direction TB
        F["1. formatCallback<br/>Set BGRA format, create CVPixelBufferPool"]
        L["2. lockCallback<br/>Get buffer from pool, lock base address"]
        U["3. unlockCallback<br/>Unlock base address"]
        D["4. displayCallback<br/>Wrap as CMSampleBuffer, enqueue to layer"]
        C["5. cleanupCallback<br/>Release pool"]
        F --> L --> U --> D --> C
    end

    subgraph PiPStack["Display Stack"]
        Layer["AVSampleBufferDisplayLayer"]
        Controller["AVPictureInPictureController<br/>(managed by PiPController)"]
        Layer --> Controller
    end

    D -->|"enqueues on main queue"| Layer
```

### PiPController Responsibilities

1. **Timebase sync.** Creates a `CMTimebase` and keeps it aligned with the player's state (playing, paused, or rate-shifted).
2. **Duration reporting.** Invalidates the PiP controller once the duration becomes known, which is required before the controls can render.
3. **Playback delegation.** Implements `AVPictureInPictureSampleBufferPlaybackDelegate` so the play, pause, and seek buttons on the PiP window route into the ``Player``.
4. **State observation.** An observer task distinguishes VLC-initiated state changes from PiP-initiated ones.
5. **Deferred pause.** Skip-without-blink by deferring the pause via task cancellation.

### Mutually Exclusive

`VideoView` and `PiPVideoView` are mutually exclusive for a given player: `set_nsobject` and vmem callbacks cannot coexist on the same `libvlc_media_player_t`.

---

## Error Handling

### Typed Throws

All fallible operations use `throws(VLCError)`:

```swift
func play() throws(VLCError) {
  guard libvlc_media_player_play(pointer) == 0 else {
    throw .playbackFailed
  }
}

func parse(timeout: Duration) async throws(VLCError) -> Metadata {
  // ...
  throw .parseTimeout
}
```

### Error Cases

| Error | When |
|---|---|
| `instanceCreationFailed` | `libvlc_new` returns nil |
| `mediaCreationFailed` | `libvlc_media_new_*` returns nil |
| `playbackFailed` | `libvlc_media_player_play` returns non-zero |
| `parseFailed` | Media parsing reports failure status |
| `parseTimeout` | Parsing exceeds specified timeout |
| `trackNotFound` | Track selection fails (invalid track ID) |
| `invalidState` | Operation attempted in wrong state |
| `operationFailed` | Generic libVLC operation failure |

All errors conform to `LocalizedError` and `CustomStringConvertible` for logging and user-facing messages.

---

## Testing Strategy

### Overview

A comprehensive **Swift Testing** suite (not XCTest) covers every
public API. Every test is an integration test that exercises the real
libVLC binary.

```
Tests/SwiftVLCTests/
├── Support/
│   ├── TestMedia.swift      # Fixture URLs (bundled resources)
│   └── Tag.swift            # Test tag definitions
├── Fixtures/
│   ├── test.mp4             # 1s, 64x64, with metadata
│   ├── twosec.mp4           # 2s, for seeking tests
│   ├── silence.wav          # Audio-only
│   └── test.srt             # Subtitle file
└── …                        # One test suite per domain area
```

### Test Tags

| Tag | Purpose | Speed |
|---|---|---|
| `logic` | Pure Swift logic, no libVLC | Fast |
| `integration` | Requires `VLCInstance` | Medium |
| `media` | Uses bundled fixture files | Medium |
| `mainActor` | Runs on `@MainActor` | Medium |
| `async` | Async tests with timeout guards | Slow |

### Testing Patterns

**Integration tests with real libVLC.** No mocking; every test creates actual `Player` and `Media` instances:

```swift
@Test(.tags(.integration, .media, .async))
func playAndWaitForState() async throws {
  let player = Player()
  try player.play(url: TestMedia.videoURL)
  // Wait for state change...
}
```

**CI execution.** GitHub Actions runs on `macos-latest` with Xcode pinned to `latest-stable` (currently 26.x) plus the Swift 6.3 open-source toolchain from swift.org, invoked via `xcrun --toolchain`. The test step is wrapped by `scripts/ci-run-with-timeouts.py`, which enforces a 10-minute wall clock and a 3-minute idle watchdog and sends SIGKILL to the process group when either fires. Three layered caches keep cold-start cost down: the libvlc xcframework (keyed on its SHA-256), compiled build products (keyed on `hashFiles` of sources and the manifest), and SPM dependency checkouts.

---

## Build & Release Infrastructure

### Scripts

| Script | Purpose |
|---|---|
| `scripts/setup-dev.sh` | First step for local repo work. Downloads the last-released xcframework into `Vendor/`, flips `Package.swift` to the local-path form, and points the Showcase app at the repo-local Swift package. Flags: `--force` (re-download), `--skip-download` (only flip local references). |
| `scripts/build-libvlc.sh` | Compiles libVLC from VideoLAN source (pinned via `VLC_HASH`) into `Vendor/libvlc.xcframework`. Applies the local VLC source patches described in README. |
| `scripts/fix-duplicate-symbols.sh` | Localizes `_json_parse_error` and `_json_read` in the chromecast plugin, which two VLC plugins each emit. Called automatically by `build-libvlc.sh` and `setup-dev.sh`. |
| `scripts/release.sh` | Cuts a versioned release, uploads the xcframework asset, pins the Showcase app to that exact Swift package version, and advances `main`. |
| `scripts/ci-use-released-xcframework.sh` | CI-only. Rewrites the current `Package.swift` `binaryTarget` to the url+checksum of the latest release tag. Run at CI job start so tests resolve against the same binary a downstream consumer would. |
| `scripts/ci-run-with-timeouts.py` | CI-only. Wraps `swift test` with wall-clock and idle timeouts; SIGKILLs the process group if either fires. |

### Package.swift resolution strategy

Published states (`main` and release tags) carry the remote form of the libvlc `binaryTarget`:

```swift
.binaryTarget(
  name: "libvlc",
  url: "https://github.com/harflabs/SwiftVLC/releases/download/vX.Y.Z/libvlc.xcframework.zip",
  checksum: "<sha256>"
)
```

That keeps the repository's default package state aligned with what downstream SPM consumers resolve. Local repo development flips the manifest back to the on-disk xcframework with `./scripts/setup-dev.sh`, which rewrites only the libvlc `binaryTarget` to:

```swift
.binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")
```

The Showcase apps follow the same split: published states pin `SwiftVLC` by exact release version, while `setup-dev.sh` rewrites the Xcode project to use the repo-local package checkout.

| Context | What `binaryTarget` looks like | Where the xcframework comes from |
|---|---|---|
| Published `main` | `url: + checksum:` of the latest release | GitHub Release asset |
| Local dev after `setup-dev.sh` | `path: "Vendor/libvlc.xcframework"` | `setup-dev.sh` (download) or `build-libvlc.sh` (build) |
| CI | rewritten in-memory to `url: + checksum:` of the latest release | SPM resolves + caches (keyed on checksum) |
| Release tag `vX.Y.Z` | `url: + checksum:` | `release.sh` uploads the zip as a release asset at that URL |
| SPM consumer pinning `X.Y.Z` | Reads the tag's `Package.swift` | SPM resolves + verifies checksum + caches |

### Release flow

`release.sh` creates a real release commit that stays on `main`.

```mermaid
flowchart LR
    BUILD["build-libvlc.sh --all"] --> XCF["Vendor/libvlc.xcframework<br/>(unstripped)"]
    XCF --> RELEASE["release.sh vX.Y.Z"]
    RELEASE --> VERIFY["Verify all required slices present"]
    VERIFY --> STRIP["strip -S"]
    STRIP --> ZIP["ditto -c -k"]
    ZIP --> SUM["swift package compute-checksum"]
    SUM --> COMMIT["Commit on main:<br/>Package.swift → url+checksum<br/>Showcase → exactVersion X.Y.Z"]
    COMMIT --> TAG["git tag vX.Y.Z"]
    TAG --> PUSH_TAG["git push origin vX.Y.Z"]
    PUSH_TAG --> GH["gh release create<br/>+ attached .zip"]
    GH --> PUSH_MAIN["git push origin HEAD:main"]
    PUSH_MAIN --> SPM["main and consumers resolve the same release"]
```

Preflight refuses releases from non-`main` branches, uncommitted changes in `Package.swift` or the Showcase project, pre-existing local or remote tags, and unauthenticated `gh`. If a pre-commit rewrite or post-write sanity check fails, the script restores `Package.swift` and the Showcase project before exiting. The tag is pushed before `main`, so if GitHub Release creation fails, `origin/main` still points at the previous good release; finish the release or delete the tag before retrying. A post-write regex guard verifies that the rewritten `Package.swift` still contains the `CLibVLC` target, catching a malformed replacement before the tag is cut.

### CI/CD

| Workflow | Trigger | Purpose |
|---|---|---|
| `test.yml` | Push / PR | Runs full test suite against the last-released xcframework on `macos-latest` + Swift 6.3 toolchain. Xcframework cached by SHA-256. |
| `claude.yml` | Issue comment / PR mention | Claude Code bot integration. |

---

## Project Structure

```
SwiftVLC/
├── Sources/
│   ├── CLibVLC/                    # C bridging layer
│   │   ├── include/vlc/            # libVLC 4.0 C headers
│   │   └── shim.c                  # va_list formatting shim
│   │
│   └── SwiftVLC/                   # Main library
│       ├── Core/                   # VLCInstance, VLCError, Logging, Duration
│       ├── Player/                 # Player, EventBridge, PlayerState, Events, ABLoop, etc.
│       ├── Media/                  # Media, Metadata, Track, Thumbnails, Statistics
│       ├── Audio/                  # AudioOutput, Equalizer, ChannelModes
│       ├── Video/                  # VideoView, AspectRatio, Adjustments, Marquee, Logo, Viewpoint
│       ├── Playlist/              # MediaList, MediaListPlayer, PlaybackMode
│       ├── Discovery/             # MediaDiscoverer, RendererDiscoverer
│       └── PiP/                   # PiPController, PiPVideoView, PixelBufferRenderer
│
├── Tests/SwiftVLCTests/            # Swift Testing suite, one file per domain
│   ├── Support/                    # TestMedia fixtures, Tag definitions
│   └── Fixtures/                   # Bundled media files (~50 KB)
│
├── Showcase/                       # Platform showcase apps
│   ├── Shared/                     # Launch-arg/accessibility contracts, app icon, and shared showcase resources
│   ├── iOS/                        # Full-featured iOS target/scheme, also enabled for Mac Catalyst
│   ├── macOS/                      # Native macOS target/scheme with Mac-tailored showcases
│   ├── tvOS/                       # Native tvOS target/scheme with TV-tailored showcases
│   ├── visionOS/                   # Native visionOS target/scheme with focused playback coverage
│   └── UITests/
│       ├── iOS/                    # Existing UI tests for the iOS/Catalyst showcase
│       ├── macOS/                  # Empty native macOS UI-test target shell
│       └── tvOS/                   # Empty tvOS UI-test target shell
│
├── Vendor/                         # libvlc.xcframework (multi-GB unstripped; release zip a few hundred MB)
│
├── scripts/
│   ├── build-libvlc.sh                   # Compile libvlc from source
│   ├── setup-dev.sh                      # Download xcframework for local dev
│   ├── release.sh                        # Cut a versioned release and advance main
│   ├── fix-duplicate-symbols.sh          # Localize duplicate json symbols
│   ├── ci-use-released-xcframework.sh    # CI: point Package.swift at latest release
│   └── ci-run-with-timeouts.py           # CI: wall-clock + idle test timeouts
│
├── .github/workflows/
│   ├── test.yml                   # CI test runner
│   └── claude.yml                 # Claude Code bot integration
│
├── Package.swift                  # SPM manifest (Swift 6.3+)
├── .swiftlint.yml                # Lint configuration
├── .swiftformat                   # Format: 2-space indent
└── README.md                     # User guide
```
