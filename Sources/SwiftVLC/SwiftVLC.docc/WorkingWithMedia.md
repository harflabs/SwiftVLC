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
``Metadata``. It runs asynchronously and honors cooperative
cancellation: canceling the enclosing `Task` aborts the parse
promptly.

```swift
let media = try Media(url: url)
let metadata = try await media.parse(timeout: .seconds(10))

print(metadata.title ?? "Unknown")
print(metadata.duration ?? "—")
print(metadata.artworkURL?.absoluteString ?? "no artwork")
```

Every libVLC metadata key is typed on ``Metadata``. Access less-common
keys through the subscript:

```swift
let now = metadata[.nowPlaying]
let encoded = metadata[.encodedBy]
```

## Tracks

A media reports its tracks once parsing has completed, or once the
player has loaded it:

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

## Options

libVLC's playback is configured through colon-prefixed option strings:

```swift
media.addOption(":network-caching=1500")
media.addOption(":start-time=30")
```

Options only affect media that has not yet started playing.

## Statistics

Real-time counters for input, demux, decoders, and output are available
while a media is loaded:

```swift
if let stats = player.statistics {
    print("Input bitrate: \(stats.inputBitrate) kbps")
    print("Dropped frames: \(stats.lostPictures)")
}
```

Values are snapshots at the moment of the call. Capture them on a
timer to display rates over time.

## Topics

### Creating media
- ``Media/init(url:)``
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

### Options and statistics
- ``Media/addOption(_:)``
- ``MediaStatistics``
- ``Player/statistics``
