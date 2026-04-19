# Handling errors

How ``VLCError`` shapes the error surface, and how typed throws let
you match on its cases exhaustively.

## One error type for the whole library

Every failable SwiftVLC API uses Swift's typed throws form, with
``VLCError`` as the only error it can produce:

```swift
public func play(url: URL) throws(VLCError)
```

The compiler therefore knows the complete set of cases a call site
might see. Pattern matching can be exhaustive, with no residual
`catch` branch needed:

```swift
do {
    try player.play(url: url)
} catch .mediaCreationFailed(let source) {
    print("Couldn't build media for: \(source)")
} catch .playbackFailed(let reason) {
    print("Playback refused: \(reason)")
} catch .invalidState(let message) {
    print("Player wasn't ready: \(message)")
} catch .operationFailed(let op) {
    print("libVLC call failed: \(op)")
}
```

## The cases at a glance

| Case | Typically triggered by |
|---|---|
| ``VLCError/instanceCreationFailed`` | `libvlc.xcframework` not linked, missing plugins, OOM |
| ``VLCError/mediaCreationFailed(source:)`` | Invalid URL, unreadable path, or bad file descriptor |
| ``VLCError/playbackFailed(reason:)`` | libVLC refused to start playback; `reason` is its last error string |
| ``VLCError/parseFailed(reason:)`` | ``Media/parse(timeout:instance:)`` ended with a non-success status |
| ``VLCError/parseTimeout`` | ``Media/parse(timeout:instance:)`` hit the requested timeout |
| ``VLCError/trackNotFound(id:)`` | No track matches the requested identifier |
| ``VLCError/invalidState(_:)`` | Operation is valid but the player isn't in the right state |
| ``VLCError/operationFailed(_:)`` | A libVLC call returned non-zero; the string names the attempted op |

## When the failure mode doesn't matter

When the control flow doesn't need to distinguish between failure
causes, `try?` reduces the result to an optional:

```swift
try? player.play(url: url)
```

## Topics

- ``VLCError``
