# Playback essentials

The shape of ``Player``, the events it publishes, and the properties
that SwiftUI binds to.

## The central type

``Player`` is `@Observable` and `@MainActor`. Each instance owns one
`libvlc_media_player_t` and one stream of ``PlayerEvent`` values. The
rest of the library's types exist to feed media to a player or to
decorate its output.

```swift
@State private var player = Player()
```

Construction allocates the underlying libVLC resources. Release
happens off the main actor in `deinit`, so tearing down a view never
stalls the UI thread.

## Observable state

Read-only properties refresh whenever libVLC reports new state. SwiftUI
binds to them directly, without a publisher or Combine adapter.

| Property | Type | Meaning |
|---|---|---|
| ``Player/state`` | ``PlayerState`` | `.idle`, `.opening`, `.buffering`, `.playing`, `.paused`, `.stopped`, `.stopping`, `.error` |
| ``Player/isPlaybackRequestedActive`` | `Bool` | User-facing playback intent for transport controls while libVLC state transitions settle |
| ``Player/bufferFill`` | `Float` | Continuously-updated cache level (`0.0…1.0`), independent of `state` |
| ``Player/currentTime`` | `Duration` | Wall-clock position, millisecond resolution |
| ``Player/duration`` | `Duration?` | `nil` until the container reports length |
| ``Player/isSeekable`` | `Bool` | Whether seek operations take effect |
| ``Player/isPausable`` | `Bool` | Whether pause/frame-step is available |
| ``Player/currentMedia`` | ``Media``? | Last item loaded |
| ``Player/audioTracks`` / ``Player/videoTracks`` / ``Player/subtitleTracks`` | `[Track]` | Track list, refreshed automatically |

### Convenience

- ``Player/isPlaying`` is `true` when `state == .playing`.
- ``Player/isActive`` is `true` while the player is opening, buffering,
  or playing.
- ``Player/isPlaybackRequestedActive`` is the best signal for a
  Play/Pause button label because it updates synchronously when a pause
  or resume request is accepted, before the native player finishes its
  state transition.

## Bindable state

The following properties are read-write and mirror their values back
to libVLC on set. Because they're observed, SwiftUI can bind controls
to them directly:

```swift
Slider(value: $player.position)   // 0.0 ... 1.0
Slider(value: $player.volume)     // 0.0 ... 1.25 (values above 1.0 amplify)
```

| Property | Range | Notes |
|---|---|---|
| ``Player/position`` | `0.0 ... 1.0` | Fractional playback position |
| ``Player/volume`` | `0.0 ... 1.25` | `1.0` is 100%; above 1.0 amplifies |
| ``Player/isMuted`` | — | Independent of volume |
| ``Player/rate`` | any positive | `1.0` is normal; practical range `0.25 ... 4.0` |
| ``Player/aspectRatio`` | ``AspectRatio`` | See <doc:DisplayingVideo> |
| ``Player/audioDelay`` / ``Player/subtitleDelay`` | `Duration` | Positive values delay the channel |
| ``Player/subtitleTextScale`` | `0.1 ... 5.0` | Clamped by libVLC |

## Control

```swift
try player.play()              // start / resume from stopped
player.pause()                 // pause current playback
player.resume()                // unpause
player.togglePlayPause()       // flip between pause/resume
player.stop()                  // async stop
player.seek(to: .seconds(30))  // absolute seek
player.seek(by: .seconds(-10)) // relative seek
player.nextFrame()             // pause + step one frame
```

Seeks are asynchronous. Observe ``Player/currentTime`` (or the
``PlayerEvent/timeChanged(_:)`` event) to detect completion.

## The raw event stream

The observable properties cover typical playback UI. When you need
event-level detail — recording transitions, snapshot completion,
program changes, custom bridging — iterate ``Player/events`` directly:

```swift
for await event in player.events {
    switch event {
    case .recordingChanged(let isRecording, let path): ...
    case .snapshotTaken(let path): ...
    default: break
    }
}
```

Multiple consumers can subscribe at the same time. Each call to
``Player/events`` returns an independent ``PlayerEvent`` stream.

## Main actor and `sending`

``Player`` is `@MainActor`; every method call must originate on the
main actor. ``Media`` is `Sendable`, so constructing it on a
background task and transferring ownership to the player is legal
and race-free:

```swift
let media = try Media(url: url)       // any actor
await MainActor.run {
    try? player.play(media)           // main actor; ownership transfers
}
```

See <doc:ConcurrencyModel> for the full isolation story.

## Topics

### Reading state
- ``Player/state``
- ``Player/currentTime``
- ``Player/duration``
- ``Player/isPlaying``
- ``Player/isActive``
- ``Player/isPlaybackRequestedActive``
- ``PlayerState``
- ``PlayerEvent``

### Controlling playback
- ``Player/play(_:)``
- ``Player/play(url:)``
- ``Player/pause()``
- ``Player/resume()``
- ``Player/stop()``
- ``Player/seek(to:)``
- ``Player/seek(by:)``
- ``Player/nextFrame()``

### Bindable properties
- ``Player/position``
- ``Player/volume``
- ``Player/isMuted``
- ``Player/rate``
