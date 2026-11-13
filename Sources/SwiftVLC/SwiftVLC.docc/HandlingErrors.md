# Handling errors

What ``VLCError`` reports synchronously, and where the failures it
cannot report arrive instead.

## One error type for library failures

SwiftVLC's throwing operations use Swift's typed throws form, so the
error in a `catch` clause is a ``VLCError`` with no casting:

```swift
do {
    try player.play(url: url)
} catch .mediaCreationFailed(let source) {
    print("Couldn't build media for: \(source)")
} catch .invalidState(let message) {
    print("Player wasn't ready: \(message)")
} catch {
    print("libVLC call failed: \(error)")
}
```

`catch` clauses still need a final unconditional branch: Swift does not
exhaustiveness-check a list of `catch` patterns, even for a typed throw.
Matching every case individually and omitting the trailing `catch` is a
compile error.

APIs whose invalid case is naturally absence use optionals instead, such
as ``Equalizer/init(preset:)`` and lookup helpers that return `nil` for
an unknown index.

Scoped closure helpers — ``Player/withAdjustments(_:)``,
``Player/withMarquee(_:)``, ``Player/withLogo(_:)``,
``MediaList/withLocked(_:)`` — use `rethrows`. They add no library
failure of their own and propagate the caller's closure errors unchanged,
including application-defined error types.

## The cases at a glance

| Case | Typically triggered by |
|---|---|
| ``VLCError/instanceCreationFailed-enum.case`` | `libvlc.xcframework` not linked, missing plugins, OOM |
| ``VLCError/mediaCreationFailed(source:)`` | Invalid URL, unreadable path, or bad file descriptor |
| ``VLCError/playbackFailed(reason:)`` | libVLC refused to start playback; `reason` is its last error string |
| ``VLCError/parseFailed(reason:)`` | ``Media/parse(timeout:instance:)`` ended with a non-success status |
| ``VLCError/parseTimeout-enum.case`` | ``Media/parse(timeout:instance:)`` hit the requested timeout |
| ``VLCError/trackNotFound(id:)`` | No track matches the requested identifier |
| ``VLCError/invalidState(_:)`` | Operation is valid but the player isn't in the right state |
| ``VLCError/invalidInput(_:)`` | A public API argument is outside its documented range |
| ``VLCError/operationFailed(_:)`` | A libVLC call returned non-zero; `"Set renderer"` identifies synchronous renderer rejection |

## Playback failures arrive asynchronously

``VLCError`` covers what a call can reject on the spot. libVLC opens
media on its own threads after ``Player/play(url:)`` returns, so `play()`
**does not throw** for an unreachable host, a failed DNS lookup, an HTTP
error status, a missing file, or media no decoder can handle.

``Player/state`` is not where those surface either. A failed session
passes through ``PlayerState/error`` and then stops, normally within the
same frame, so the value a view renders is ``PlayerState/stopped`` — the
same as after an ordinary stop.

Read ``Player/failure``. It is observable, set when a session ends in a
failure, and cleared by the next ``Player/load(_:)`` or `play`:

```swift
struct PlayerScreen: View {
    let player: Player

    var body: some View {
        VideoView(player)
            .overlay {
                if let failure = player.failure {
                    FailureBanner(kind: failure) { try? player.play() }
                }
            }
    }
}
```

``PlaybackFailureKind`` names the stage that failed:
``PlaybackFailureKind/source`` (the address could not be opened or read),
``PlaybackFailureKind/demux`` (the container was not understood),
``PlaybackFailureKind/decoder``, ``PlaybackFailureKind/renderer``,
``PlaybackFailureKind/output``, or ``PlaybackFailureKind/unknown``.

Outside a view, or when the final position matters, consume
``Player/terminalOutcomes``. It delivers one lossless result per session,
frozen before the stop resets ``Player/currentTime``:

```swift
for await outcome in player.terminalOutcomes {
    switch outcome.cause {
    case .failure(let kind):
        report(kind, at: outcome.finalTimeline.time)
    case .naturalEnd:
        advanceToNextItem()
    case .requestedStop, .replacement, .cancellation, .unknownNativeStop:
        break
    }
}
```

### What is not reported as a failure

Two conditions end as ``PlaybackTerminalCause/naturalEnd`` because libVLC
itself sees a clean end of stream:

- **A connection dropped mid-stream.** When the server closes the
  connection without an error and the transfer cannot be resumed, the
  input simply runs out of data. Compare
  ``PlaybackFinalTimeline/time`` with ``PlaybackFinalTimeline/duration``
  before treating a natural end as "finished" for media whose duration is
  known.
- **A truncated file.** Playback ends naturally at the last readable
  sample.

A stream that stalls without closing never ends at all: ``Player/state``
stays ``PlayerState/playing`` and ``Player/playbackHealth`` reports
``PlaybackHealthState/stalled(_:)`` after
``Player/playbackHealthStallThreshold`` (two seconds). See
<doc:PlaybackEssentials> for the health surface.

## Topics

- ``VLCError``
- ``Player/failure``
- ``PlaybackFailureKind``
- ``Player/terminalOutcomes``
- ``PlaybackTerminalOutcome``
- ``PlaybackTerminalCause``
- ``PlaybackFinalTimeline``
