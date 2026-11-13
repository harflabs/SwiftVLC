# Logging

Pipe libVLC's internal logs into your app through an `AsyncStream`,
filtered by severity.

## Subscribe to a stream

Any ``VLCInstance`` exposes a ``VLCInstance/logStream(minimumLevel:)``.
Start a task and iterate:

```swift
Task {
    for await entry in VLCInstance.shared.logStream(minimumLevel: .warning) {
        print("[\(entry.level)] \(entry.module ?? "vlc"): \(entry.message)")
    }
}
```

Each ``LogEntry`` carries a severity ``LogLevel``, the message text,
and the libVLC module name (e.g. `avcodec`, `http`, `mp4`) when the
emitter provided one.

## Multiple consumers

Several tasks can subscribe at once, each filtering independently:

```swift
Task { for await e in instance.logStream(minimumLevel: .error) {
    diagnostics.record(e)
}}

Task { for await e in instance.logStream(minimumLevel: .debug) {
    devConsole.append(e)
}}
```

The libVLC callback is installed lazily on the first subscription and
removed when the last consumer's stream terminates, so an app that never
subscribes pays nothing.

## Severity levels

``LogLevel`` conforms to `Comparable`, so filtering is a natural
comparison:

| Level | Typical use |
|---|---|
| ``LogLevel/debug`` | Verbose diagnostics for investigation |
| ``LogLevel/notice`` | Normal informational messages |
| ``LogLevel/warning`` | Potential problems that don't stop playback |
| ``LogLevel/error`` | Failures that may affect playback |

## Severity reclassification

A few upstream libVLC messages declare themselves ``LogLevel/error`` even
though they come from normal probe or self-healing paths — when Apple's
hardware decoder is offered a codec it does not accept, for instance,
libVLC logs the rejection at error level before falling back to software.
SwiftVLC reclassifies those structural probe failures to
``LogLevel/warning``, so a subscriber filtering at ``LogLevel/error`` sees
only entries where playback actually broke.

Reclassification happens once on the libVLC log thread, before any
subscriber sees the entry, and inspects the message string only for
entries that arrive at ``LogLevel/error``. Terminal failures are
untouched: `"Codec 'XXXX' (...) is not supported."`, the core decoder
cascade's "no decoder found", stays at ``LogLevel/error``. Recoverable
paused-seek prefetch and PCR rebuffer diagnostics are visible at
``LogLevel/warning``, while neighbouring PCR messages that do not match
libVLC's complete recovery templates remain errors.

## Ending a stream

An `AsyncStream` finishes automatically when the ``VLCInstance`` that
owns it is released, or when the consuming task is cancelled. No
explicit close is required.

## Topics

- ``VLCInstance/logStream(minimumLevel:)``
- ``LogEntry``
- ``LogLevel``
