# ``SwiftVLC``

A Swift 6 wrapper around libVLC 4.0 for SwiftUI apps.

## Overview

SwiftVLC binds directly to libVLC's C API, with no Objective-C
intermediary.

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

- **Observable state.** ``Player`` is `@Observable` and `@MainActor`.
  SwiftUI views track ``Player/state``, ``Player/currentTime``,
  ``Player/duration``, and the track lists without manual bridging.
- **Typed errors.** SwiftVLC's throwing operations use
  `throws(VLCError)`. Scoped closure helpers use `rethrows` and
  propagate the caller's own errors unchanged. See <doc:HandlingErrors>.
- **Structured events.** Playback, discovery, logging, and dialog
  prompts surface through `AsyncStream`. Multiple consumers can
  subscribe concurrently; each gets an independent subscription.
- **Ownership-aware overlays.** ``Marquee``, ``Logo``, and
  ``VideoAdjustments`` are `~Copyable` `~Escapable` views scoped to the
  player's lifetime, so the compiler rejects code that would store a
  dangling pointer.
- **Tested against real libVLC.** The Swift Testing suite exercises the
  C bridge with no mocks; CI runs it on pull requests and on `main`.

New to the library? Start with <doc:GettingStarted>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:PlaybackEssentials>
- <doc:WorkingWithMedia>
- <doc:DisplayingVideo>

### Feature guides

- <doc:TextSubtitles>
- <doc:PictureInPicture>
- <doc:MediaPlaylists>
- <doc:AudioFeatures>
- <doc:VideoOverlays>
- <doc:DiscoveryAndCasting>

### Reference guides

- <doc:HandlingErrors>
- <doc:ConcurrencyModel>
- <doc:IntegrationTopology>
- <doc:Logging>
- <doc:ComparisonWithVLCKit>
- <doc:VLCKitPortingGuide>

### Playback

- ``Player``
- ``PlayerState``
- ``PlayerEvent``
- ``PlayerEventEnvelope``
- ``PlayerEventLane``
- ``EventBufferingPolicy``
- ``PlayerRole``
- ``VLCInstance``
- ``AppleAudioSessionPolicy``

### Transport results

- ``SeekRequest``
- ``SeekOutcome``
- ``FrameStepRequest``
- ``FrameStepOutcome``
- ``PlayerStopOutcome``
- ``RecastOutcome``
- ``PlaybackTerminalOutcome``
- ``PlaybackTerminalCause``
- ``PlaybackFailureKind``
- ``PlaybackFinalTimeline``
- ``PlaybackGeneration``

### Playback health

- ``PlaybackHealthSnapshot``
- ``PlaybackHealthState``
- ``PlaybackHealthEvent``
- ``PlaybackHealthEventKind``
- ``PlaybackHealthCounters``
- ``PlaybackHealthFailure``
- ``PlaybackStallReason``
- ``PlaybackWaitingReason``
- ``PlaybackStatus``

### Media

- ``Media``
- ``MediaType``
- ``MediaSlave``
- ``MediaSlaveType``
- ``Metadata``
- ``MetadataKey``
- ``Track``
- ``TrackType``
- ``FrameRateRatio``
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
- ``TeletextKey``

### Audio

- ``Equalizer``
- ``AudioOutput``
- ``AudioDevice``
- ``StereoMode``
- ``MixMode``

### Text subtitles

- ``TextSubtitleSnapshot``
- ``TextSubtitleRegion``
- ``TextSubtitlePlacement``
- ``WebVTTPlacement``

### Picture-in-Picture

- ``PiPVideoView``
- ``PiPController``
- ``PiPController/DeferredPauseOutcome``
- ``PiPStartResult``
- ``PiPEvent``
- ``PiPEventEnvelope``
- ``PiPStopCause``
- ``PiPStopReason``
- ``PiPSnapshot``
- ``PiPOverlaySupport``

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
