# Getting started

This guide walks through adding SwiftVLC to a project, loading a
media, and rendering it on screen.

## Add the package

The quickest path is through Xcode. Choose **File → Add Package
Dependencies** and paste the repository URL; Xcode resolves the latest
release automatically.

```
https://github.com/harflabs/SwiftVLC.git
```

To add it from a `Package.swift` manifest, pin to the current release.
The version string lives on the
[releases page](https://github.com/harflabs/SwiftVLC/releases).

```swift
dependencies: [
    .package(url: "https://github.com/harflabs/SwiftVLC.git", from: "x.y.z")
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftVLC"])
]
```

SwiftVLC requires Swift 6.3 and supports iOS 18, macOS 15, tvOS 18,
and macCatalyst 18.

## Play a URL

```swift
import SwiftUI
import SwiftVLC

struct PlayerView: View {
    @State private var player = Player()

    var body: some View {
        VideoView(player)
            .task {
                try? player.play(url: URL(string: "https://example.com/stream.m3u8")!)
            }
    }
}
```

``VideoView`` hosts the player's output, and ``Player`` publishes its
state through `@Observable`, which is enough for SwiftUI to redraw as
playback progresses.

``Player/play(url:)`` expects a direct media stream or file URL. It
does not auto-resolve `.pls` or classic `.m3u` playlist containers; use
``MediaListPlayer`` or resolve the playlist to its inner stream URL
before handing it to ``Player``. HLS `.m3u8` URLs are supported here
because they are streaming manifests rather than playlists of separate
media URLs.

## Drive the UI from state

Most controls read a handful of observable properties directly:

```swift
Text(player.state.description)
ProgressView(value: player.position)
Button(player.isPlaying ? "Pause" : "Play") {
    player.isPlaying ? player.pause() : try? player.play()
}
```

<doc:PlaybackEssentials> documents the full observable surface;
<doc:DisplayingVideo> covers sizing and aspect ratios.

## Handle errors as typed throws

Every failable API throws ``VLCError`` specifically, so `catch`
clauses can match individual cases:

```swift
do {
    try player.play(url: url)
} catch .mediaCreationFailed(let source) {
    print("Bad URL: \(source)")
} catch {
    print("Playback error: \(error)")
}
```

See <doc:HandlingErrors> for the full case list.

## Next steps

- <doc:PlaybackEssentials>: the shape of ``Player``.
- <doc:WorkingWithMedia>: parsing metadata, tracks, and slaves.
- <doc:DisplayingVideo>: aspect ratios and layer lifecycle.
- <doc:PictureInPicture>: background playback and floating windows.
