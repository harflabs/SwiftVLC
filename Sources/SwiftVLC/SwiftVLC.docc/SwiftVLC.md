# ``SwiftVLC``

A Swift 6 wrapper around libVLC 4.0 for SwiftUI apps.

## Overview

SwiftVLC binds directly to libVLC's C API, with no Objective-C
intermediary. The resulting surface uses `@Observable` for player
state, `AsyncStream` for events, and typed throws for errors, so
playback integrates with SwiftUI the same way any other `@Observable`
model does.

- **Observable state.** ``Player`` is `@Observable` and `@MainActor`.
  SwiftUI views track `state`, `currentTime`, `duration`, and the
  track lists without manual bridging.
- **Typed errors.** Every failable API uses `throws(VLCError)`, so
  the compiler sees the full error surface and a general `catch` is
  never needed.
- **Structured events.** Playback, discovery, logging, and dialog
  prompts all surface through `AsyncStream`. Multiple consumers can
  subscribe concurrently.
- **Ownership-aware overlays.** ``Marquee``, ``Logo``, and
  ``VideoAdjustments`` are `~Copyable` `~Escapable` views scoped to
  the player's lifetime, so the compiler rejects any code that would
  store a dangling pointer.
- **Tested against real libVLC.** A comprehensive Swift Testing suite
  exercises the full C bridge with no mocks or fakes, and CI runs it
  on every push.

### First play

```swift
import SwiftUI
import SwiftVLC

struct ContentView: View {
    @State private var player = Player()

    var body: some View {
        VideoView(player)
            .task { try? player.play(url: videoURL) }
    }
}
```

### Where next

If you're new to the library, read <doc:GettingStarted>. From there,
<doc:PlaybackEssentials> covers the shape of ``Player`` and
<doc:DisplayingVideo> covers the rendering side. The feature guides
below walk through Picture-in-Picture, playlists, casting, and the
audio and video overlay APIs.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:PlaybackEssentials>
- <doc:WorkingWithMedia>
- <doc:DisplayingVideo>

### Feature guides

- <doc:PictureInPicture>
- <doc:MediaPlaylists>
- <doc:AudioFeatures>
- <doc:VideoOverlays>
- <doc:DiscoveryAndCasting>

### Reference guides

- <doc:HandlingErrors>
- <doc:ConcurrencyModel>
- <doc:Logging>
- <doc:ComparisonWithVLCKit>

### Playback

- ``Player``
- ``PlayerState``
- ``PlayerEvent``
- ``PlayerRole``
- ``VLCInstance``

### Media

- ``Media``
- ``MediaType``
- ``MediaSlave``
- ``MediaSlaveType``
- ``Metadata``
- ``MetadataKey``
- ``Track``
- ``TrackType``
- ``MediaStatistics``

### Playlists

- ``MediaList``
- ``MediaListPlayer``
- ``PlaybackMode``

### Video display

- ``VideoView``
- ``AspectRatio``

### Overlays and adjustments

- ``Marquee``
- ``Logo``
- ``OverlayPosition``
- ``VideoAdjustments``
- ``Viewpoint``

### Audio

- ``Equalizer``
- ``AudioOutput``
- ``AudioDevice``
- ``StereoMode``
- ``MixMode``

### Picture-in-Picture

- ``PiPVideoView``
- ``PiPController``

### Chapters, titles, and programs

- ``Title``
- ``Chapter``
- ``NavigationAction``
- ``ABLoopState``
- ``Program``

### Discovery and casting

- ``MediaDiscoverer``
- ``DiscoveryService``
- ``DiscoveryCategory``
- ``RendererDiscoverer``
- ``RendererItem``
- ``RendererEvent``
- ``RendererService``

### Dialog prompts

- ``DialogHandler``
- ``DialogEvent``
- ``DialogID``
- ``LoginRequest``
- ``QuestionRequest``
- ``QuestionType``
- ``ProgressInfo``
- ``ProgressUpdate``

### Diagnostics

- ``LogEntry``
- ``LogLevel``

### Typed values

- ``PlaybackPosition``
- ``Volume``
- ``PlaybackRate``
- ``SubtitleScale``
- ``EqualizerGain``

### Errors

- ``VLCError``
