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

Construction allocates the underlying libVLC resources. `deinit` moves
blocking native release calls off the main actor, so view teardown does
not perform that work on the UI thread.

For the default shared instance, call
``VLCInstance/prewarmShared(priority:)`` during app launch when possible.
That moves libVLC's one-time startup work out of the first SwiftUI
player screen.

## Observable state

Read-only properties refresh whenever libVLC reports new state. SwiftUI
binds to them directly, without a publisher or Combine adapter.

| Property | Type | Meaning |
|---|---|---|
| ``Player/state`` | ``PlayerState`` | `.idle`, `.opening`, `.buffering`, `.playing`, `.paused`, `.stopped`, `.stopping`, `.error` |
| ``Player/isPlaying`` | `Bool` | User-facing playback signal for Play/Pause controls while libVLC state transitions settle |
| ``Player/isPlaybackRequestedActive`` | `Bool` | Lower-level playback intent mirrored by PiP and external transport controls |
| ``Player/bufferFill`` | `Float` | Continuously-updated cache level (`0.0…1.0`), independent of `state` |
| ``Player/currentTime`` | `Duration` | Wall-clock position, millisecond resolution |
| ``Player/duration`` | `Duration?` | `nil` until the container reports length |
| ``Player/isSeekable`` | `Bool` | Whether seek operations take effect |
| ``Player/isPausable`` | `Bool` | Whether pause/frame-step is available |
| ``Player/currentMedia`` | ``Media``? | Last item loaded |
| ``Player/audioTracks`` / ``Player/videoTracks`` / ``Player/subtitleTracks`` | `[Track]` | Track list, refreshed automatically |

### Convenience

- ``Player/isPlaying`` is the best signal for a Play/Pause button label
  because it updates synchronously when a play, pause, or resume request
  is accepted, before the native player finishes its state transition.
- ``Player/isActive`` is `true` while the player is opening, buffering,
  or playing.
- ``Player/state`` is the strict libVLC lifecycle state. It can lag
  transport intent briefly during PiP and other asynchronous transitions.

## Observable state and checked mutations

SwiftVLC keeps raw playback observations read-only. Mutations go through
explicit methods so invalid state and libVLC rejection are visible instead
of being hidden in writable properties:

```swift
Slider(
    value: Binding(
        get: { player.playbackPosition.rawValue },
        set: { try? player.seek(to: PlaybackPosition($0)) }
    )
)

Slider(
    value: Binding(
        get: { Double(player.audioVolume.rawValue) },
        set: { try? player.setAudioVolume(Volume(Float($0))) }
    ),
    in: 0...1.25
)
```

| Property | Range | Notes |
|---|---|---|
| ``Player/position`` | `0.0 ... 1.0` | Read-only fractional playback position |
| ``Player/volume`` | `0.0 ... 1.25` | Read-only requested volume shadow |
| ``Player/isMuted`` | — | Independent of volume |
| ``Player/rate`` | `0.25 ... 4.0` via ``PlaybackRate`` | Read-only current rate |
| ``Player/aspectRatio`` | ``AspectRatio`` | See <doc:DisplayingVideo> |
| ``Player/audioDelay`` / ``Player/subtitleDelay`` | `Duration` | Read-only; positive values delay the channel |
| ``Player/subtitleTextScale`` | `0.1 ... 5.0` | Read-only current scale |

### Typed equivalents

Each typed value clamps finite input to its valid range, maps `NaN` to a
safe named default, and exposes named constants. Use the explicit
mutation methods for changes:

```swift
try player.seek(to: PlaybackPosition.end)
try player.setAudioVolume(.muted)
try player.setPlaybackRate(.double)
player.setSubtitleScale(.doubleSize)
```

The typed wrappers — ``PlaybackPosition``, ``Volume``, ``PlaybackRate``,
``SubtitleScale``, ``EqualizerGain`` — are `Hashable`, `Comparable`,
and `ExpressibleByFloatLiteral` so they fit naturally into existing
SwiftUI bindings, set membership, and comparisons.

## Control

```swift
try player.play()              // start / resume from stopped
player.pause()                 // pause current playback
player.resume()                // unpause
player.togglePlayPause()       // flip between pause/resume
player.stop()                  // async stop
try player.seek(to: .seconds(30))  // absolute seek
try player.seek(by: .seconds(-10)) // relative seek
player.nextFrame()             // pause + step one frame
```

Seeks throw when the current media is not seekable or the requested time
is outside the known playable range. Native completion is asynchronous;
observe ``Player/currentTime`` or ``PlayerEvent/timeChanged(_:)`` for
the final libVLC timestamp.

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
- ``Player/seek(to:)-(Duration)``
- ``Player/seek(to:)-(PlaybackPosition)``
- ``Player/seek(by:)``
- ``Player/nextFrame()``

### Observable properties
- ``Player/position``
- ``Player/volume``
- ``Player/isMuted``
- ``Player/rate``

### Typed accessors
- ``Player/playbackPosition``
- ``Player/audioVolume``
- ``Player/playbackRate``
- ``Player/subtitleScale``
- ``Player/setAudioVolume(_:)``
- ``Player/setPlaybackRate(_:)``
- ``Player/setSubtitleScale(_:)``
