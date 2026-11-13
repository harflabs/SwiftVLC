# Playback essentials

The shape of ``Player``, the events it publishes, and the properties
that SwiftUI binds to.

## The central type

``Player`` is `@Observable` and `@MainActor`. Each instance owns one
`libvlc_media_player_t` and publishes one stream of ``PlayerEvent``
values. The rest of the library feeds media to a player or decorates its
output.

```swift
@State private var player = Player()
```

Construction allocates the libVLC resources. `deinit` moves the blocking
native release calls off the main actor, so view teardown does not do
that work on the UI thread.

Call ``VLCInstance/prewarmShared(priority:)`` at app launch to move
libVLC's one-time startup work out of the first player screen.

## Observable state

These properties refresh whenever libVLC reports new state. SwiftUI binds
to them directly, with no publisher or Combine adapter.

| Property | Type | Meaning |
|---|---|---|
| ``Player/state`` | ``PlayerState`` | `.idle`, `.opening`, `.buffering`, `.playing`, `.paused`, `.stopped`, `.stopping`, `.error` |
| ``Player/nativePlaybackState`` | ``PlayerState`` | Synchronous native snapshot for transport decisions; not observable |
| ``Player/failure`` | ``PlaybackFailureKind``? | Why the most recent session failed; stays set after `state` settles at `.stopped` |
| ``Player/isPlaying`` | `Bool` | User-facing playback signal for Play/Pause controls while libVLC state transitions settle |
| ``Player/isPlaybackRequestedActive`` | `Bool` | Lower-level playback intent mirrored by PiP and external transport controls |
| ``Player/bufferFill`` | `Float` | Continuously-updated cache level (`0.0…1.0`), independent of `state` |
| ``Player/playbackHealth`` | ``PlaybackHealthSnapshot`` | Generation-scoped progress, renderer state, and typed wait/stall classification |
| ``Player/currentTime`` | `Duration` | Wall-clock position, millisecond resolution |
| ``Player/duration`` | `Duration?` | `nil` whenever the length is unknown — libVLC reports unknown as a non-positive value, and live input never reports one |
| ``Player/isSeekable`` | `Bool` | Whether seek operations take effect |
| ``Player/isPausable`` | `Bool` | Whether pause/frame-step is available |
| ``Player/currentMedia`` | ``Media``? | Last item loaded |
| ``Player/audioTracks`` / ``Player/videoTracks`` / ``Player/subtitleTracks`` | `[Track]` | Track list, refreshed automatically |

Which "is it playing?" signal to read:

- ``Player/isPlaying`` is the right label source for a Play/Pause button:
  it updates synchronously when a play, pause, or resume request is
  accepted, before the native player finishes transitioning.
- ``Player/isActive`` is `true` while opening, buffering, or playing.
- ``Player/state`` is the strict libVLC lifecycle state and can briefly
  lag transport intent during PiP and other asynchronous transitions.
- ``Player/nativePlaybackState`` reads the native handle synchronously
  when code must tell that lag from the current lifecycle state.

## Checked mutations

Raw playback observations are read-only; changes go through explicit
methods so invalid state and libVLC rejection are visible at the call
site instead of being swallowed by a property setter:

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
    in: 0...2.0
)
```

| Read this | Range | Change it with |
|---|---|---|
| ``Player/position`` | `0.0 ... 1.0` | ``Player/seek(to:fast:)-(PlaybackPosition,_)`` |
| ``Player/volume`` | `0.0 ... 2.0` | ``Player/setAudioVolume(_:)`` |
| ``Player/rate`` | `0.25 ... 4.0` | ``Player/setPlaybackRate(_:)`` |
| ``Player/audioDelay`` / ``Player/subtitleDelay`` | `Duration`; positive delays the channel | ``Player/setAudioDelay(_:)`` / ``Player/setSubtitleDelay(_:)`` |
| ``Player/subtitleTextScale`` | `0.1 ... 5.0` | ``Player/setSubtitleScale(_:)`` |

``Player/isMuted`` and ``Player/aspectRatio`` are the exceptions: they
are plain settable properties, because neither can fail.

### Typed values

``PlaybackPosition``, ``Volume``, ``PlaybackRate``, ``SubtitleScale``,
and ``EqualizerGain`` clamp finite input to their range, map `NaN` to a
named default, and expose named constants. All five are `Hashable`,
`Comparable`, and `ExpressibleByFloatLiteral`, so float literals work
wherever one is expected:

```swift
try player.seek(to: PlaybackPosition.end)
try player.setAudioVolume(.muted)
try player.setPlaybackRate(.double)
player.setSubtitleScale(.doubleSize)
```

``Player/setPlaybackRate(_:)`` confirms only that libVLC accepted the
command into its control path. The active input applies rate changes
asynchronously and may fall back — commonly to `1.0` for unsupported
streams — so read ``Player/rate`` after the transition when the effective
setting matters. Even then it is a control setting, not a measurement of
decoded or presented frame throughput.

When ``Player/supportsEffectivePlaybackRateEvents`` is `true`,
``Player/effectivePlaybackRateResolutions`` reports
``EffectivePlaybackRateResolution`` values and invalidates the observable
``Player/rate``. Each carries the native-handle and playback generation
captured at callback entry, so queued work can reject a retired handle or
superseded session. It is not a per-request completion: rapid requests
carry no IDs, a queued request is silent when its resolved rate is
unchanged, and with no input — or if native queuing fails — the stream
may repeat the current effective value.

## Control

```swift
try player.play()                  // start, or resume from stopped
player.pause()                     // pause current playback
player.resume()                    // unpause
player.togglePlayPause()           // flip between pause/resume
player.stop()                      // asynchronous stop
try player.seek(to: .seconds(30))  // absolute seek
try player.seek(by: .seconds(-10)) // relative seek
player.nextFrame()                 // pause + step one frame
```

``Player/load(_:)`` only loads. On a player that is already running an
input it stops that input and holds the new media for the next
``Player/play()``, which starts it on a fresh native handle. Nothing
plays until you call `play()`, with or without a video view attached.

### Seeking

The strict seeks — ``Player/seek(to:fast:)-(Duration,_)``, its
``PlaybackPosition`` overload, and ``Player/seek(by:fast:)`` — throw when
the media is not seekable or the target is outside the known playable
range. For live, timeshift, and unknown-duration media they cannot
validate a target at all; use the best-effort, non-throwing pair instead:

```swift
player.seek(toPosition: 0.95, fast: true)  // fractional, best effort
player.jump(by: .seconds(-10))             // native relative jump
```

Both return whether libVLC accepted the command. Acceptance is not
arrival: native completion is asynchronous in every form. When the caller
must distinguish an authoritative landing from rejection, timeout, or
supersession, use the `request` variants —
``Player/requestSeek(to:fast:)-(Duration,_)``,
``Player/requestSeek(toPosition:fast:)``, ``Player/requestJump(by:)`` —
and await the returned ``SeekRequest``:

```swift
let request = try player.requestSeek(to: .seconds(30), fast: false)
guard request.initialOutcome == .pending else { return }

switch await request.outcome {
case .settled: updateTransportUI()
case .timedOut, .superseded, .rejected, .inaccurate: recoverTransportUI()
case .pending: break // `outcome` is always terminal
}
```

Each request is bound to its playback generation and timeline revision. A
matching native time sample settles it; a newer seek or a media lifecycle
change reports ``SeekOutcome/superseded``; a missing sample reports
``SeekOutcome/timedOut`` after a bounded wait. A seek issued while paused
settles from a direct clock read after native seek-end, because a paused
input may not produce another timing point until playback resumes.

### Frame stepping

``Player/nextFrame()`` is fire-and-forget. Use
``Player/requestNextFrame()`` when the caller needs an exact terminal:

```swift
let request = player.requestNextFrame()
switch await request.outcome {
case .submitted(let time, _): updateFrameTime(time)
case .noFrame: showEndOfMedia()
case .failed, .invalidEvidence, .timedOut, .superseded, .rejected: recoverTransportUI()
case .pending: break // `outcome` is always terminal
}
```

``FrameStepOutcome/submitted(time:position:)`` proves that libVLC accepted
that request's exact picture for output submission and updated its video
clock. It does not claim display hardware scanned the picture out; only
device qualification establishes visible output.

## The raw event stream

The observable properties cover typical playback UI. For event-level
detail — recording transitions, snapshot completion, program changes,
custom bridging — iterate ``Player/events``:

```swift
for await event in player.events {
    switch event {
    case .recordingChanged(let isRecording, let path): ...
    case .snapshotTaken(let path): ...
    default: break
    }
}
```

Each access returns an independent subscription, so several consumers can
iterate at once. ``Player/events`` is lossy by default; see
<doc:ConcurrencyModel> for the buffering policies and when to choose
another lane.

## Playback health

``PlayerState/playing`` means libVLC entered its playing lifecycle; it does
not prove that a decoder or output is still advancing. Read
``Player/playbackHealth`` when UI or diagnostics need that distinction. It
separates expected waits such as opening, buffering, seeking, adaptive track
switches, and the first frame from source, decoder, display, audio-output, and
direct-renderer stalls.

```swift
for await event in player.playbackHealthEvents {
    switch event.kind {
    case .firstPresentedFrame:
        hidePoster()
    case .stalled(let reason):
        showRecoveryUI(for: reason)
    case .recovered:
        hideRecoveryUI()
    case .terminalFailure(let failure):
        report(failure, snapshot: event.snapshot)
    default:
        break
    }
}
```

Snapshots are sampled every ``Player/playbackHealthSamplingInterval``
(250 ms) and a stage is not classified as stalled until
``Player/playbackHealthStallThreshold`` (2 s) elapses, which caps
observation writes at four per second regardless of frame rate. The
cumulative ``PlaybackHealthCounters`` carry native progress plus
direct-renderer flush, rebuild, replacement, backpressure, retry, and
failure counts without one event per frame.

Every snapshot and event carries the current ``PlaybackGeneration``.
Direct frames captured before a media replacement are rejected at the
renderer boundary, and first-decoded/first-presented events fire once per
generation. A late subscriber receives the latest value; snapshots retain
the most recent stall reason and its stall and recovery timestamps, so
the pair stays reconstructible after recovery.

Direct renderer recovery re-offers the triggering frame ten times at
16-millisecond intervals. When that budget is exhausted, a terminal
``PlaybackHealthFailure/renderer`` is published on the next health
sample — normally within about 410 ms of recovery beginning, though
queue starvation can delay delivery.

## Main actor and `sending`

``Player`` is `@MainActor`, so every call must originate there.
``Media`` is `Sendable`, so building one off-actor and transferring it in
is race-free. See <doc:ConcurrencyModel>.

## Topics

### Reading state
- ``Player/state``
- ``Player/failure``
- ``Player/playbackHealth``
- ``Player/playbackHealthSnapshots``
- ``Player/playbackHealthEvents``
- ``PlaybackHealthSnapshot``
- ``PlaybackHealthState``
- ``PlaybackHealthEvent``
- ``PlaybackHealthCounters``
- ``Player/currentTime``
- ``Player/duration``
- ``Player/isPlaying``
- ``Player/isActive``
- ``Player/isPlaybackRequestedActive``
- ``PlayerState``
- ``PlayerEvent``

### Controlling playback
- ``Player/load(_:)``
- ``Player/play()``
- ``Player/play(_:)``
- ``Player/play(url:)``
- ``Player/togglePlayPause()``
- ``Player/pause()``
- ``Player/resume()``
- ``Player/stop()``
- ``Player/seek(to:fast:)-(Duration,_)``
- ``Player/seek(to:fast:)-(PlaybackPosition,_)``
- ``Player/seek(by:fast:)``
- ``Player/seek(toPosition:fast:)``
- ``Player/requestSeek(to:fast:)-(Duration,_)``
- ``Player/requestSeek(to:fast:)-(PlaybackPosition,_)``
- ``Player/requestSeek(toPosition:fast:)``
- ``Player/jump(by:)``
- ``Player/requestJump(by:)``
- ``SeekRequest``
- ``SeekOutcome``
- ``Player/nextFrame()``
- ``Player/requestNextFrame()``
- ``FrameStepRequest``
- ``FrameStepOutcome``

### Raw observable values
- ``Player/position``
- ``Player/volume``
- ``Player/isMuted``
- ``Player/rate``
- ``Player/subtitleTextScale``

### Typed accessors and setters
- ``Player/playbackPosition``
- ``Player/audioVolume``
- ``Player/playbackRate``
- ``Player/subtitleScale``
- ``Player/setAudioVolume(_:)``
- ``Player/setPlaybackRate(_:)``
- ``Player/setSubtitleScale(_:)``
- ``Player/setAudioDelay(_:)``
- ``Player/setSubtitleDelay(_:)``
- ``PlaybackPosition``
- ``Volume``
- ``PlaybackRate``
- ``SubtitleScale``
