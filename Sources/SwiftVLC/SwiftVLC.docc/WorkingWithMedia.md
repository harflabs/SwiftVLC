# Working with media

Creating ``Media``, parsing metadata, enumerating tracks, and
attaching external subtitle or audio files.

## Creating media

```swift
// A URL works for both local files and network streams.
let media = try Media(url: URL(string: "https://example.com/movie.mp4")!)

// A filesystem path, for convenience.
let media = try Media(path: "/Users/me/video.mkv")

// An already-open file descriptor (libVLC does not close it).
let media = try Media(fileDescriptor: fd)
```

``Media`` is `Sendable`, so it's safe to build on any task and hand to
the player from the main actor.

## Parsing metadata

Parsing reads the container to discover duration, tracks, and
``Metadata``. It runs asynchronously and honours cooperative
cancellation: cancelling the enclosing `Task` aborts the parse promptly.

```swift
let media = try Media(url: url)
let metadata = try await media.parse(timeout: .seconds(10))

print(metadata.title ?? "Unknown")
print(metadata.duration ?? "—")
print(metadata.artworkURL?.absoluteString ?? "no artwork")
```

Media that is already parsed — including media a ``Player`` has opened —
returns its metadata without another request. libVLC runs one parse per
media at a time, so a second call made while one is in flight is not
joined to it and throws ``VLCError/parseFailed(reason:)``.

Common keys are typed properties on ``Metadata``; every libVLC key is
reachable through the subscript:

```swift
let now = metadata[.nowPlaying]
let encoded = metadata[.encodedBy]
```

## Tracks

``Media/parse(timeout:instance:)`` returns metadata only. Read the track
list separately, once parsing has completed or the player has loaded the
media:

```swift
let audio = media.tracks().filter { $0.type == .audio }
audio.forEach { print($0.name, $0.language ?? "—", $0.channels ?? 0) }
```

The ``Player`` exposes the same lists as ``Player/audioTracks``,
``Player/videoTracks``, and ``Player/subtitleTracks``, kept up to date
as tracks appear mid-stream.

## External subtitles and audio

A "slave" is an extra track attached to a media, typically a sidecar
`.srt` subtitle file or an alternate audio dub. Attach one before
playback begins:

```swift
try media.addSlave(
    from: URL(fileURLWithPath: "/path/to/sub.srt"),
    type: .subtitle
)
```

Or attach during playback through the player (and select it
immediately):

```swift
try player.addExternalTrack(
    from: URL(fileURLWithPath: "/path/to/alt-audio.m4a"),
    type: .audio,
    select: true
)
```

libVLC loads the file in the background; with `select: true` the new
track replaces the selected track of that type as soon as it appears.
The file stays attached to the media, so it loads again whenever that
media plays, and adding the same URL again does not create a second
copy.

## Options

libVLC's playback is configured through colon-prefixed option strings:

```swift
media.addOption(":network-caching=1500")
```

Options only affect media that has not yet started playing.

To resume playback, load the full media and seek once the player is
seekable and its duration is known:

```swift
let request = try player.requestSeek(to: .seconds(savedElapsed))
guard await request.outcome == .settled else { return }
```

Do not reach for `:start-time` instead. It clips the timeline: a
60-second file with `:start-time=20` reports a 40-second duration, and
seeking to 5 seconds shows content from 25 seconds into the original.

For HTTP and HTTPS streams, use the typed initializer when the request
needs a per-media identity:

```swift
let media = try Media(
    url: streamURL,
    httpUserAgent: "CustomApp/1.0",
    httpReferrer: "https://example.com/catalog"
)
```

The ``Media/setHTTPUserAgent(_:)`` and ``Media/setHTTPReferrer(_:)`` helpers
provide the same options for an existing media created through another
initializer. Apply them before parsing or playback begins.

Cookie forwarding is handled by libVLC's internal cookie jar and is
enabled by default. The bundled libVLC build does not expose a string
media option for injecting an initial `Cookie` header or arbitrary
request headers such as `Authorization` or `Origin`. Use a presigned
URL, proxy, or your own `URLSession` fetch/materialization step for
streams that require those headers.

## Statistics

Real-time counters for input, demux, decoders, and output are available
while a media is loaded:

```swift
if let stats = player.statistics {
    print("Input bitrate: \(stats.inputBitrate) kbps")
    print("Dropped frames: \(stats.lostPictures)")
}
```

Values are snapshots at the moment of the call. Sample them on a timer to
display rates over time.

## Thumbnails

``Media/thumbnail(at:width:height:crop:seekMode:timeout:instance:)``
decodes one frame and returns PNG data, without a player:

```swift
let png = try await media.thumbnail(at: .seconds(60), width: 320)
```

It is cancellable up to the point libVLC accepts the request; see
<doc:ConcurrencyModel>.

## Topics

### Creating media
- ``Media/init(url:)``
- ``Media/init(url:httpUserAgent:httpReferrer:)``
- ``Media/init(path:)``
- ``Media/init(fileDescriptor:)``

### Parsing
- ``Media/parse(timeout:instance:)``
- ``Metadata``
- ``MetadataKey``

### Tracks
- ``Media/tracks()``
- ``Track``
- ``TrackType``

### Slaves
- ``Media/addSlave(from:type:priority:)``
- ``Media/slaves``
- ``Media/clearSlaves()``
- ``Player/addExternalTrack(from:type:select:)``
- ``MediaSlave``
- ``MediaSlaveType``

### Thumbnails
- ``Media/thumbnail(at:width:height:crop:seekMode:timeout:instance:)``
- ``ThumbnailSeekMode``

### Options and statistics
- ``Media/addOption(_:)``
- ``Media/setHTTPUserAgent(_:)``
- ``Media/setHTTPReferrer(_:)``
- ``MediaStatistics``
- ``Player/statistics``
