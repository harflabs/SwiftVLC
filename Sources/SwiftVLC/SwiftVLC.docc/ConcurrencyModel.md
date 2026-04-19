# Concurrency model

Which types are isolated, which are `Sendable`, and how `sending`
transfers flow between them.

## Isolation at a glance

| Type | Isolation |
|---|---|
| ``Player``, ``MediaListPlayer``, ``Equalizer``, ``PiPController`` | `@MainActor` |
| ``Marquee``, ``Logo``, ``VideoAdjustments`` | `@MainActor`, also `~Copyable`/`~Escapable` |
| ``Media``, ``MediaList``, ``VLCInstance``, ``MediaDiscoverer``, ``RendererDiscoverer`` | `Sendable` (any actor) |
| ``Track``, ``Metadata``, ``PlayerState``, ``PlayerEvent``, ``VLCError``, … | `Sendable` value types |

The main-actor types own stateful C resources: players, equalizers,
the PiP pipeline. The `Sendable` ones are safe to create and pass
around freely. A typical pattern is to build a ``Media`` on a
background task, transfer it to the main actor, and play it from
there.

## The sending transfer

``Player/load(_:)`` and ``Player/play(_:)`` take `sending Media`:

```swift
public func load(_ media: sending Media)
```

`sending` asks the compiler to transfer ownership of `media` across
the isolation boundary. Because the caller cannot retain a reference
after the call, there can never be a race between a background task
still holding `media` and the main-actor player using it.

```swift
Task.detached {
    let media = try Media(url: url)       // built off-actor
    await MainActor.run {
        try? player.play(media)           // ownership transfers in
    }
}
```

## Event streams

Events, logs, dialogs, and discoverers all surface through
`AsyncStream`. The streams are multiplexed: calling ``Player/events``
twice returns two independent streams, both of which receive every
event broadcast after their creation.

```swift
Task { for await e in player.events { handleA(e) } }
Task { for await e in player.events { handleB(e) } }
```

Backpressure is `bufferingNewest`; slow consumers drop oldest events
rather than block the callback thread.

## Cancellation

Every async API that waits on libVLC honors task cancellation:

- ``Media/parse(timeout:instance:)``: canceling the enclosing task
  stops the parse.
- ``Media/thumbnail(at:width:height:crop:timeout:instance:)``:
  canceling destroys the in-flight thumbnail request.
- Streams finish when their owning type (`Player`, `VLCInstance`, or
  a discoverer) is released.

## Deinit off the main actor

Several main-actor types release their C resources on a background
queue during `deinit`. The underlying `libvlc_*_release` calls can
block for several milliseconds, and for seconds under load, so doing
the work inline would stall SwiftUI transitions. Teardown runs
asynchronously by design: the event manager is detached first, then
stop and release execute on a utility queue.

No waiting is required on the caller's side. From the outside, `deinit`
simply returns.

## Topics

- ``Player``
- ``Media``
- ``VLCInstance``
- ``PlayerEvent``
- ``DialogHandler``
- ``LogEntry``
