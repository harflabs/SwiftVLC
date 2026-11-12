# Handling errors

How ``VLCError`` shapes the error surface, and how typed throws let
you match on its cases exhaustively.

## One error type for library failures

Every failure originating in SwiftVLC's own throwing operations is a
``VLCError``. Those APIs use Swift's typed throws form:

```swift
public func play(url: URL) throws(VLCError)
```

The compiler therefore knows the complete set of cases those calls might
produce. Pattern matching can be exhaustive, with no residual `catch`
branch needed:

```swift
do {
    try player.play(url: url)
} catch .instanceCreationFailed {
    print("libVLC could not be initialized")
} catch .mediaCreationFailed(let source) {
    print("Couldn't build media for: \(source)")
} catch .playbackFailed(let reason) {
    print("Playback refused: \(reason)")
} catch .parseFailed(let reason) {
    print("Parsing failed: \(reason)")
} catch .parseTimeout {
    print("Parsing timed out")
} catch .trackNotFound(let id) {
    print("No track matched: \(id)")
} catch .invalidState(let message) {
    print("Player wasn't ready: \(message)")
} catch .invalidInput(let message) {
    print("Bad argument: \(message)")
} catch .operationFailed(let op) {
    if op == "Set renderer" {
        print("The selected renderer could not be applied")
    } else {
        print("libVLC call failed: \(op)")
    }
}
```

APIs whose invalid case is naturally absence still use optionals, such
as ``Equalizer/init(preset:)`` and lookup helpers that return `nil` for
an unknown index.

Scoped closure helpers such as `Player.withAdjustments(_:)`,
`Player.withMarquee(_:)`, `Player.withLogo(_:)`, and
`MediaList.withLocked(_:)` use `rethrows`. They do not introduce a new
library failure, but they propagate any error thrown by the caller's
closure, including application-defined error types.

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

``VLCError`` covers what a call can reject on the spot. Whether media can
actually be played is not known at that point: libVLC opens it on its own
threads after ``Player/play(url:)`` returns. `play()` therefore **does not
throw** for an unreachable host, a failed DNS lookup, an HTTP error status,
a missing file, or media no decoder can handle. Those failures are
reported afterwards.

``Player/state`` is not the place to look for them. A failed session
passes through ``PlayerState/error`` and then stops, normally within the
same frame, so the value a view actually renders is
``PlayerState/stopped``, the same as after an ordinary stop.

Read ``Player/failure`` instead. It is observable, set when a session ends
in a failure, and stays set until the next `load` or `play`:

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

``PlaybackFailureKind`` names the stage that failed: `.source` (the
address could not be opened or read), `.demux` (the container was not
understood), `.decoder`, `.renderer`, `.output`, or `.unknown`.

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
stays `.playing` and ``Player/playbackHealth`` reports
``PlaybackHealthState/stalled(_:)`` after two seconds.

## When the failure mode doesn't matter

When the control flow doesn't need to distinguish between failure
causes, `try?` reduces the result to an optional:

```swift
try? player.play(url: url)
```

## Topics

- ``VLCError``
- ``Player/failure``
- ``PlaybackFailureKind``
- ``Player/terminalOutcomes``
- ``PlaybackTerminalOutcome``
- ``PlaybackTerminalCause``
