# VLCKit porting guide

A working migration map from VLCKit-era idioms to their SwiftVLC
replacements.

## Overview

<doc:ComparisonWithVLCKit> covers *why* the two libraries differ; this
page covers *how* to move code between them. Each section below takes
one idiom that VLCKit code leans on and shows the SwiftVLC construct
that replaces it — including the places where SwiftVLC deliberately
behaves differently and a mechanical translation would be wrong.

| VLCKit idiom | SwiftVLC replacement |
|---|---|
| `player.position = x` (silently no-ops) | ``Player/seek(to:)-(PlaybackPosition)``, or lenient ``Player/seek(toPosition:fast:)`` |
| `VLCMediaPlayerState.ended` | ``PlayerEvent/endReached-enum.case`` / ``Player/didReachEnd`` |
| Mid-playback `setRendererItem:` | ``Player/recast(to:)`` |
| `currentAudioTrackIndex = -1` | ``Player/selectedAudioTrack`` `= nil` |
| Rebuffering via state callbacks | ``Player/bufferFill`` `< 1` while `.playing` |
| `mediaMetaDataDidChange` delegate | one `await` of ``Media/parse(timeout:instance:)`` |
| Delegate thread-marshaling proxies | ``Player/events(policy:filter:)``, ``Player/stateTransitions`` |
| `audio.volume` in `0...200` | ``Volume`` in `0.0 ... 2.0` |
| Synchronous `stop()` | ``Player/stopAndWait()``, ``Player/shutdown()`` |
| Polling `videoSize` / `hasVideoOut` | ``Player/videoSize``, ``Player/hasVideoOutput``, ``Player/activeVideoOutputs`` — all observable |
| Subtitle text scale by feel | ``SubtitleScale/init(approximatePoints:basePoints:)`` |

## Unconditional position writes

VLCKit's `position` setter accepted anything: writing to it on a
non-seekable stream was a silent no-op, so player UIs scrubbed
optimistically and let the engine ignore them.

SwiftVLC's strict seeks refuse instead of pretending.
``Player/seek(to:fast:)`` and
``Player/seek(to:)-(PlaybackPosition)`` throw
``VLCError/invalidState(_:)`` when the current media is not seekable
(and ``VLCError/invalidInput(_:)`` for out-of-range targets), so a
seek that cannot happen is visible at the call site. Check
``Player/isSeekable`` before exposing scrub controls.

For code that genuinely wants VLCKit's old contract — live and
timeshift content where seekability flickers and a failed seek is
routine, not exceptional — use the lenient pair instead:
``Player/seek(toPosition:fast:)`` and ``Player/jump(by:)``. They
return `false` instead of throwing, which makes them the drop-in
replacement for an unconditional `position` write:

```swift
// VLCKit: fire and forget
player.position = 0.95

// SwiftVLC: same intent, with an honest result
let accepted = player.seek(toPosition: PlaybackPosition(0.95))
```

## The .ended state

VLCKit reported natural end-of-media as its own state,
`VLCMediaPlayerState.ended`, distinct from `.stopped`. libVLC 4
collapses the two: both arrive as the same `stopped` transition, so
the distinction VLCKit handed you for free no longer exists at the
engine level.

SwiftVLC synthesizes it back. When a `stopped` arrives that no
library-issued stop, error, or media replacement accounts for, the
player emits ``PlayerEvent/endReached-enum.case`` immediately after the
`.stateChanged(.stopped)` it belongs to, and sets
``Player/didReachEnd`` for `@Observable` consumers. Port
`.ended` checks to one of those two, not to ``PlayerState/stopped``,
which fires for every teardown cause.

One suppression to know about: ``PlayerEvent/endReached-enum.case`` is not
emitted while a ``MediaListPlayer`` drives the player, because list
advancement stops the handle between items — use the list player's
own events to track item boundaries there.

## Mid-playback renderer changes

VLCKit let you call `setRendererItem:` while playing and handled the
restart internally. libVLC 4 applies a renderer only before a native
handle's first play, so the naive port — stop, set renderer, play —
forces you to rebuild drawable attachment and observation by hand.

``Player/recast(to:)`` is the supported translation: it switches the
active renderer mid-playback on the *same* ``Player``, replacing the
native handle under the hood while drawable attachment, observation,
and app-side Now-Playing wiring all survive. Pass `nil` to return to
local playback. The call awaits the new session and resumes from the
captured position once the new session reports seekability.

It is not entirely transparent — its documentation lists what resets
with the new session: A-B loop bounds, track/chapter/title selection,
and DVB program selection (elementary-stream and program ids can
differ per session, so re-selection is app policy), and system
Picture-in-Picture backed by the replaced handle stops.

## Index-based track selection

VLCKit selected tracks by array index, with `-1` as the "off"
sentinel (`currentAudioTrackIndex = -1`). Indexes are positional and
shift as tracks appear, which made live-stream track UIs fragile.

SwiftVLC selects by stable identity. Each ``Track`` carries a
`String` `id` that is stable for the session, and selection is an
optional property write:

```swift
// VLCKit
player.currentAudioTrackIndex = -1               // off

// SwiftVLC
player.selectedAudioTrack = nil                  // off
player.selectedSubtitleTrack = subtitleTracks[0] // on, by identity
```

``Player/selectedAudioTrack`` and ``Player/selectedSubtitleTrack``
read back the engine's actual selection, and setting either to `nil`
deselects — there is no sentinel value to remember.

## Rebuffering spinners

VLCKit surfaced every buffering episode through its state callbacks,
and players showed spinners off the back of them.

SwiftVLC synthesizes the ``PlayerState/buffering`` state **only
before playback starts**: once the player is `.playing`, later
``PlayerEvent/bufferingProgress(_:)`` events update
``Player/bufferFill`` without demoting the lifecycle state, so a
brief network stall does not bounce your UI through a state change.

Derive mid-playback rebuffer spinners from the fill level instead.
``Player/bufferFill`` is published continuously and is not gated by the
state enum, so it covers the initial load too. A bare
`bufferFill < 1` check flickers, though: ``Player/bufferFill`` updates
constantly during playback and a healthy live stream hovers a little
below `1.0`. Use hysteresis — demote on a clear dip, promote at full or
as soon as playback advances:

```swift
@Observable @MainActor
final class RebufferModel {
  private(set) var isRebuffering = false
  private var lastTime: Duration = .zero

  func update(state: PlayerState, event: PlayerEvent) {
    guard state == .playing else { isRebuffering = false; return }
    switch event {
    case .bufferingProgress(let fill):
      if fill < 0.9 { isRebuffering = true }       // clear dip: show
      else if fill >= 1.0 { isRebuffering = false } // full: hide
    case .timeChanged(let time):
      if time > lastTime { isRebuffering = false }  // advanced: not stalled
      lastTime = time
    default:
      break
    }
  }
}
```

The split thresholds (`0.9` down, `1.0` up) keep a value oscillating
around one level from toggling the spinner, and the `timeChanged`
promotion hides it for live streams that play steadily below `1.0`.

## Live metadata

VLCKit's `VLCMediaDelegate.mediaMetaDataDidChange(_:)` pushed
metadata updates as they were discovered. SwiftVLC has no equivalent
callback; the supported pattern is to parse once, up front:

```swift
let media = try Media(url: url)
let metadata = try await media.parse()
try player.play(media)
```

``Media/parse(timeout:instance:)`` awaits the full result — metadata
plus track list — and honors task cancellation, so there is nothing
to observe afterwards for file-backed media: everything the engine
will know is in the returned ``Metadata``.

The limitation to state plainly: live ICY-style in-stream metadata —
the now-playing titles that internet radio streams update
mid-playback — is **not** observed. A port that relied on
`mediaMetaDataDidChange` for radio station displays has no SwiftVLC
replacement today; re-parsing mid-stream is not the answer either,
as parse reads from the source, not from the playing session.

## Delegate thread-marshaling proxies

VLCKit callbacks arrive on libVLC's threads, so mature codebases
accumulated proxy objects — an `NSLock` around mutable state, a
`DispatchQueue.main.async` hop per delegate method — to make the
callbacks safe to consume.

Delete them. SwiftVLC's events are `AsyncStream`s you can iterate
from the main actor directly — ``Player/events(policy:filter:)`` for
the raw firehose with an explicit buffering policy, and
``Player/stateTransitions`` for a lossless stream of lifecycle
changes — and ``Player`` itself is `@Observable` and `@MainActor`,
so most UI never touches a stream at all:

```swift
// VLCKit: delegate + manual main-queue hop
func mediaPlayerStateChanged(_ notification: Notification!) {
    DispatchQueue.main.async { self.updateUI() }
}

// SwiftVLC: consume on the main actor, no marshaling
for await state in player.stateTransitions {
    updateUI(for: state)
}
```

See <doc:ConcurrencyModel> for the full isolation map, including the
one rule the old proxies never had to follow: the `filter` closure
of ``Player/events(policy:filter:)`` runs on libVLC's event thread
and must never block on the main actor.

## The 0-200 volume scale

VLCKit's `audio.volume` was an integer in `0...200`, where `100`
meant 100% (0 dB) and values above it were software gain.

SwiftVLC's ``Volume`` is the same scale divided by 100: a `Float` in
`0.0 ... 2.0`, where `1.0` is 100% — unity gain, 0 dB — and the
ceiling (`2.0`) is the same +6 dB software boost VLCKit's `200`
gave you. Out-of-range values clamp on
construction, so the translation is mechanical:

```swift
// VLCKit
player.audio.volume = 150

// SwiftVLC
try player.setAudioVolume(Volume(1.5))
```

``Player/setAudioVolume(_:)`` throws if libVLC rejects the change
(no audio output yet); ``Player/audioVolume`` is the observable
read-back.

## Synchronous stop

VLCKit's `stop()` could be treated as synchronous: code commonly
called it and immediately deactivated the audio session or released
the view. libVLC 4's stop is asynchronous, and SwiftVLC keeps it
that way — ``Player/stop()`` returns immediately and the native stop
completes later, signalled by `.stateChanged(.stopped)`.

The awaitable forms are the port targets:

- ``Player/stopAndWait()`` suspends until the native stop completes
  and the audio/video outputs are released. Use it before anything
  that races the output drain:

  ```swift
  await player.stopAndWait()
  try AVAudioSession.sharedInstance()
      .setActive(false, options: .notifyOthersOnDeactivation)
  ```

  Deactivating the session right after a fire-and-forget `stop()`
  fails session-busy while the audio output is still alive — this is
  the single most common porting bug from VLCKit's synchronous-stop
  habit.

- ``Player/shutdown()`` is the awaitable full teardown: after it
  returns, no libVLC thread owned by the player is draining, its
  streams are finished, and the player is an inert no-op. Reach for
  it when the player's end-of-life must complete *before* something
  else, rather than on `deinit`'s background schedule.

## Aspect ratio and fill

VLCKit drove the picture shape through `videoAspectRatio` (a `"w:h"`
C string) and `videoCropGeometry`. SwiftVLC replaces both with the
typed ``Player/aspectRatio`` / ``AspectRatio``:

| VLCKit | SwiftVLC |
| --- | --- |
| `videoAspectRatio = nil` (source shape) | ``AspectRatio/default`` |
| `videoAspectRatio = "16:9"` (force shape) | ``AspectRatio/ratio(_:_:)`` |
| Fill/cover the view | ``AspectRatio/fill`` |

The semantics match VLCKit/libVLC 3:

- ``AspectRatio/default`` keeps the source aspect, fitted inside the
  view with letterbox/pillarbox bars.
- ``AspectRatio/ratio(_:_:)`` forces the display aspect, **stretching**
  the source to that shape (so `.ratio(4, 3)` on a 2.40:1 source shows a
  distorted 4:3 picture), then fits the shaped picture in the view.
- ``AspectRatio/fill`` covers the view, preserving the source aspect and
  cropping the overflow — no distortion.

The mode is a `Player` property: it survives the native-handle swaps that
back ``Player/recast(to:)`` and a stopped drawable-hosted restart, and it
tracks live drawable-size changes (rotation, split-screen) — set it once
and it sticks.

## Subtitle auto-selection

libVLC picks a subtitle track on each load, following its own
preferences: a stream's *forced* or *default* subtitle flag, then the
`sub-language` preference, then the `sub-track` index. SwiftVLC does
not override this, so by default a freshly loaded media may come up with
a subtitle already showing — ``Player/selectedSubtitleTrack`` is
non-`nil` after the track list arrives.

Two ways to get "off unless the user asks":

- **Bias the instance.** Leave `sub-language` empty and `sub-track`
  at `-1` (both are the libVLC defaults), and disable external-file
  detection if you never side-load `.srt` files:

  ```swift
  let instance = try VLCInstance(
    arguments: VLCInstance.defaultArguments + ["--no-sub-autodetect-file"]
  )
  ```

  This suppresses language/index/file-driven selection, but a stream that
  flags a *forced* or *default* subtitle can still auto-select it.

- **Deselect per media (authoritative).** When the subtitle tracks first
  appear for a media, clear the selection unless the user has chosen one:

  ```swift
  for await event in player.events {
    if case .tracksChanged = event, !userPickedSubtitle {
      player.selectedSubtitleTrack = nil
    }
  }
  ```

  This is the only way to guarantee "off" regardless of stream flags;
  set ``Player/selectedSubtitleTrack`` again when the user opts in.

## Topics

- ``Player/aspectRatio``
- ``AspectRatio``
- ``Player/selectedSubtitleTrack``
- ``Player/seek(toPosition:fast:)``
- ``Player/jump(by:)``
- ``PlayerEvent/endReached-enum.case``
- ``Player/didReachEnd``
- ``Player/recast(to:)``
- ``Player/selectedAudioTrack``
- ``Player/selectedSubtitleTrack``
- ``Player/bufferFill``
- ``Player/events(policy:filter:)``
- ``Player/stateTransitions``
- ``Player/stopAndWait()``
- ``Player/shutdown()``
- ``Volume``
