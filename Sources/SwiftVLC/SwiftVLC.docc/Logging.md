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
and the libVLC module name (e.g. `avcodec`, `http`, `rtsp`) when the
emitter provided one.

## Multiple consumers

Multiple tasks can subscribe at the same time, and each stream filters
independently:

```swift
Task { for await e in instance.logStream(minimumLevel: .error) {
    diagnostics.record(e)
}}

Task { for await e in instance.logStream(minimumLevel: .debug) {
    devConsole.append(e)
}}
```

The underlying libVLC callback is installed lazily on the first
subscription and removed when the last consumer's stream terminates.

## Severity levels

``LogLevel`` conforms to `Comparable`, so filtering is a natural
comparison:

| Level | Typical use |
|---|---|
| ``LogLevel/debug`` | Verbose diagnostics for investigation |
| ``LogLevel/notice`` | Normal informational messages |
| ``LogLevel/warning`` | Potential problems that don't stop playback |
| ``LogLevel/error`` | Failures that may affect playback |

## Ending a stream

An `AsyncStream` finishes automatically when the ``VLCInstance`` that
owns it is released, or when the consuming task is cancelled. No
explicit close is required.

## Topics

- ``VLCInstance/logStream(minimumLevel:)``
- ``LogEntry``
- ``LogLevel``
