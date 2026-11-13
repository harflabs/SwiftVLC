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

The main-actor types own stateful C resources: players, equalizers, the
PiP pipeline. The `Sendable` ones are safe to create and pass around
freely — build a ``Media`` on a background task, transfer it to the main
actor, play it there.

## Synchronous Observation reentrancy

Swift Observation runs an `onChange` callback synchronously, before the
mutation body that triggered it, so an observer can call back into a
``Player`` before the older control has reached libVLC.

SwiftVLC gives every accepted control invocation a monotonic per-control
identity and captures the native-handle and playback generations before
publishing its Observation change:

- A newer invocation of the same control wins, including a no-op that restores
  the value which was current when the observer ran.
- A synchronous `load(_:)`, `play(_:)`, native-handle replacement, or
  `shutdown()` supersedes an older control. The older call returns without
  writing through the successor handle. A throwing control reports a native
  error only when that invocation actually reached the handle it captured.
- Independent controls do not supersede one another. For example, a mute
  command issued by a volume observer remains valid unless media or native
  identity also changes.
- Native refreshes publish a sampled value only while both its source identity
  and the corresponding user-control revision remain current. A refresh can
  never overwrite a newer command or copy a retiring media's tracks into its
  successor.

``Equalizer`` applies the same last-invoked-wins rule across its band and
preamp APIs. These guarantees cover synchronous reentrancy as well as
ordinary main-actor serialization, so applications never need to defer
control changes out of Observation callbacks.

## The sending transfer

``Player/load(_:)`` and ``Player/play(_:)`` take `sending Media`:

```swift
public func load(_ media: sending Media)
```

`sending` asks the compiler to transfer ownership of `media` across
the isolation boundary. After the call, the caller cannot keep using
the transferred reference, which prevents a background task from racing
the main-actor player through the same `Media` object.

```swift
let media = try Media(url: url)       // built on any actor
await MainActor.run {
    try? player.play(media)           // ownership transfers in
}
```

## Event streams

Events, logs, dialogs, and discoverers all surface through `AsyncStream`.
The streams are multiplexed: calling ``Player/events`` twice returns two
independent subscriptions, each offered the events broadcast after its
creation, subject to its own filter and buffering policy.

```swift
Task { for await e in player.events { handleA(e) } }
Task { for await e in player.events { handleB(e) } }
```

Each stream's buffering policy is chosen by what losing an event costs:

| Stream | Policy |
|---|---|
| ``Player/events`` / ``Player/events(policy:filter:)`` | `.newest(64)` by default — lossy, because it carries ~30 Hz clock samples |
| ``Player/timingEvents`` | Bounded and deliberately coalescing: only the newest clock sample means anything |
| ``Player/controlEvents``, ``Player/stateTransitions``, ``Player/terminalOutcomes``, ``DialogHandler/dialogs``, ``RendererDiscoverer/events`` | Unbounded — one-shot events that do not come round again |

So a slow consumer of a lossy stream drops its own oldest buffered events
rather than blocking the callback thread or other subscribers, and a
consumer that must not miss a lifecycle transition uses a lossless lane
or passes `.unbounded` with a filter that keeps the timing firehose out
of the buffer.

The `filter` closure of ``Player/events(policy:filter:)`` runs on libVLC's
event thread for every event. Keep it fast, and never block on the main
actor inside it: native teardown joins that thread while detaching
callbacks, so a filter waiting on the main actor can deadlock teardown
against the very thread it is stalling.

## Cancellation and stream termination

Parsing and thumbnail generation are cooperatively cancellable:

- ``Media/parse(timeout:instance:)``: cancelling the enclosing task
  stops the parse.
- ``Media/thumbnail(at:width:height:crop:seekMode:timeout:instance:)``:
  cancelling before libVLC accepts the request returns immediately. Once
  accepted, SwiftVLC waits for the terminal thumbnail event so callback
  and request teardown are complete before the task returns.

Other asynchronous operations state their own completion contract.
``Player/stopAndWaitForOutcome()`` and ``Player/shutdown()`` wait for
native lifecycle teardown rather than honouring cancellation;
``Player/stopAndWait()`` is the version-1 compatibility action that
discards the bounded stop outcome.

Streams finish when their owning type — `Player`, `VLCInstance`, or a
discoverer — is released.

## Deinit off the main actor

Several main-actor types release their C resources on a background queue
during `deinit`. The underlying `libvlc_*_release` calls can block for
milliseconds, or seconds under load, so doing that work inline would
stall SwiftUI transitions. Teardown is asynchronous by design: the event
manager is detached first, then stop and release run on a utility queue.
From the outside, `deinit` simply returns; nothing to wait on.

When end-of-life must complete *before* something else — deactivating an
audio session, tearing down a drawable — use ``Player/shutdown()`` rather
than relying on `deinit`'s background schedule.

## Topics

- ``Player``
- ``Media``
- ``VLCInstance``
- ``PlayerEvent``
- ``PlayerEventEnvelope``
- ``EventBufferingPolicy``
- ``Player/events(policy:filter:)``
- ``Player/stateTransitions``
- ``Player/controlEvents``
- ``Player/timingEvents``
- ``Player/shutdown()``
- ``Player/stopAndWaitForOutcome()``
- ``DialogHandler``
- ``LogEntry``
