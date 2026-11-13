# Getting started

Add SwiftVLC to a project, load media, and render it on screen.

## Add the package

In Xcode, choose **File → Add Package Dependencies** and paste the
repository URL:

```
https://github.com/harflabs/SwiftVLC.git
```

From a `Package.swift` manifest:

```swift
dependencies: [
    .package(url: "https://github.com/harflabs/SwiftVLC.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftVLC"])
]
```

SwiftVLC requires Swift 6.3 with Xcode 26.4 or later and supports iOS 18,
macOS 15, tvOS 18, visionOS 2, and Mac Catalyst 18.

## Prepare libVLC at launch

The first libVLC instance does one-time plugin and decoder setup. Start
that work at launch so the first playback screen does not pay for it
while SwiftUI is pushing the view:

```swift
import SwiftUI
import SwiftVLC

@main
struct MyApp: App {
    init() {
        VLCInstance.prewarmShared()
    }

    var body: some Scene {
        WindowGroup { PlayerView() }
    }
}
```

If your app has an explicit loading phase, await
``VLCInstance/prepareShared(priority:)`` before presenting playback UI.

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

``VideoView`` hosts the player's output and ``Player`` publishes its
state through `@Observable`, which is all SwiftUI needs to redraw as
playback progresses.

``Player/play(url:)`` expects a direct media stream or file URL. HLS
`.m3u8` manifests work here; `.pls` and classic `.m3u` playlist
containers do not — see <doc:MediaPlaylists>.

## Drive the UI from state

Most controls read observable properties directly:

```swift
Text(player.state.description)
ProgressView(value: player.position)
Button(player.isPlaying ? "Pause" : "Play") {
    player.togglePlayPause()
}
```

<doc:PlaybackEssentials> documents the full observable surface;
<doc:DisplayingVideo> covers sizing and aspect ratios.

## Handle errors as typed throws

SwiftVLC's throwing operations all throw ``VLCError``, so `catch`
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

`play(url:)` only reports what libVLC rejects synchronously. An
unreachable host or undecodable media fails later — see
<doc:HandlingErrors>.

## Next steps

- <doc:PlaybackEssentials>: the shape of ``Player``.
- <doc:WorkingWithMedia>: parsing metadata, tracks, and slaves.
- <doc:DisplayingVideo>: aspect ratios and snapshots.
- <doc:PictureInPicture>: background playback and floating windows.
