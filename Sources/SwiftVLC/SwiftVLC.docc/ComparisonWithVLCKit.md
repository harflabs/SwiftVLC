# SwiftVLC vs VLCKit

Both libraries embed VLC's playback engine into Apple apps, but the
integration they hand back to the developer looks very different.
This page walks through where they diverge and which trade-offs apply
to each.

## What they are

**VLCKit** is VideoLAN's own wrapper around libVLC. It is written
primarily in Objective-C and distributed for macOS, iOS, and tvOS. Its
in-progress 4.0 line expands the platform surface to visionOS and
watchOS. It has been the canonical answer for embedding VLC on Apple
platforms for over a decade, and ships as three CocoaPods (`VLCKit`,
`MobileVLCKit`, `TVVLCKit`) or as pre-built frameworks via Carthage.

**SwiftVLC** is a Swift 6 binding to libVLC's C API, with no
Objective-C layer in between. It targets only modern Apple platforms
(iOS 18+, macOS 15+, tvOS 18+, visionOS 2+, macCatalyst 18+) and ships exclusively
through Swift Package Manager.

## libVLC generation

| | VLCKit | SwiftVLC |
|---|---|---|
| Stable line | libVLC 3.x | libVLC 4.0 |
| libVLC 4.0 port | Still in alpha | Shipping as the stable line |

VLCKit's stable 3.x branch tracks libVLC 3.0 and is actively
maintained. Its 4.0 line has been in alpha since early 2025 and
continues to iterate. SwiftVLC is already built against libVLC 4.0 on
its stable line, which makes the newer libVLC features available on a
non-prerelease today. Those features include subsecond seek precision,
the new track-selection API, two simultaneous subtitle tracks, and a
richer metadata surface.

## Language and integration surface

VLCKit is Objective-C (roughly 85% by SLOC). Calling it from Swift
routes through the C → Objective-C → Swift bridge: types are
`NSObject` subclasses, events arrive via delegate protocols and
`NSNotificationCenter`, and errors are `NSError` instances.

SwiftVLC compiles Swift 6.3 against libVLC's C headers directly. There
are no `NS` types, no bridging header, and no Objective-C runtime in
the call path.

```swift
// VLCKit: delegate callbacks plus NSNotification
class ViewController: UIViewController, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    override func viewDidLoad() {
        player.delegate = self
        player.drawable = videoView
        player.media = VLCMedia(url: url)
        player.play()
    }
    func mediaPlayerStateChanged(_ notification: Notification!) { /* … */ }
    func mediaPlayerTimeChanged(_ notification: Notification!) { /* … */ }
}

// SwiftVLC: @Observable plus SwiftUI
struct PlayerView: View {
    @State var player = Player()
    var body: some View {
        VideoView(player)
            .task { try? player.play(url: url) }
    }
}
```

## Concurrency model

VLCKit predates Swift concurrency. Its types are not `Sendable`, there
is no `@MainActor` isolation, and callers are expected to hop to the
main thread manually for UI-adjacent work.

SwiftVLC is strict-concurrency native:

- ``Player`` is `@MainActor` and `@Observable`.
- ``Media``, ``MediaList``, ``VLCInstance``, ``MediaDiscoverer``, and
  ``RendererDiscoverer`` are `Sendable`, so they can be created on any
  task and handed to the player.
- ``Player/load(_:)`` takes `sending Media`, so the compiler enforces
  ownership transfer across isolation.
- ``Marquee``, ``Logo``, and ``VideoAdjustments`` are `~Copyable` and
  `~Escapable`, binding their lifetime to the player at compile time.

See <doc:ConcurrencyModel> for the full isolation map.

## Events and errors

| | VLCKit | SwiftVLC |
|---|---|---|
| Playback events | Delegate + `NSNotificationCenter` | `AsyncStream<PlayerEvent>` |
| State changes | KVO / delegate callbacks | `@Observable` properties |
| Errors | `NSError` codes and out-params | `throws(VLCError)`, typed and exhaustive |
| Logging | Delegate protocol | `AsyncStream<LogEntry>` with level filtering |
| Dialog prompts | Delegate protocol | `AsyncStream<DialogEvent>` |

Multiple consumers can subscribe to any SwiftVLC stream concurrently;
each receives every event broadcast after creation.

## SwiftUI

VLCKit exposes a `UIView`/`NSView` drawable. Wiring it into SwiftUI
means writing your own `UIViewRepresentable`, coordinating lifetime,
and re-publishing state yourself.

SwiftVLC ships ``VideoView``, ``PiPVideoView``, and a ``PiPController``
that handle the view bridge, the drawable attachment, and the
sample-buffer pipeline for Picture-in-Picture. See
<doc:DisplayingVideo> and <doc:PictureInPicture>.

## Distribution

| | VLCKit | SwiftVLC |
|---|---|---|
| Swift Package Manager | Not officially supported (open since 2022) | Yes, and the only supported method |
| CocoaPods | `VLCKit` / `MobileVLCKit` / `TVVLCKit` | No |
| Carthage binaries | Yes | No |
| Pre-built framework | Yes | xcframework distributed via the SPM `.binaryTarget` |

## Platforms and deployment targets

| | VLCKit 3.x | VLCKit 4.0 (alpha) | SwiftVLC |
|---|---|---|---|
| iOS | 8.4+ | Supported in alpha | 18+ |
| macOS | 10.9+ | Supported in alpha | 15+ |
| tvOS | 10.2+ | Supported in alpha | 18+ |
| visionOS | Not supported | Supported in alpha | 2+ |
| watchOS | Not supported | Supported in alpha | Not supported |
| macCatalyst | Not supported | Not supported | 18+ |

## License

- **libVLC** itself is LGPLv2.1 or later. Both libraries link against
  this same binary dependency.
- **VLCKit** is LGPLv2.1 or later.
- **SwiftVLC** is MIT for the Swift wrapper code. The bundled libVLC
  xcframework remains under LGPLv2.1, and its terms propagate to
  anything that embeds it.

Either choice requires your shipped app to meet libVLC's LGPL
requirements.

## When to pick which

**Pick VLCKit if:**

- You need to support older OS versions (iOS 8.4+, macOS 10.9+).
- You need watchOS today (via VLCKit 4.0 alpha).
- You have an existing Objective-C codebase where the delegate /
  notification idioms fit naturally.
- You prefer a long-established library with many years of production
  use, even if the 4.0 port is still in alpha.

**Pick SwiftVLC if:**

- Your project targets iOS 18+ / macOS 15+ / tvOS 18+ / visionOS 2+.
- You want `@Observable`, `AsyncStream`, typed throws, and strict
  concurrency without writing bridging code.
- You're building on SwiftUI and want `VideoView(player)` to be the
  whole video setup.
- You want libVLC 4.0 features today on a stable release line.
- You're integrating via Swift Package Manager only.

Both libraries are actively maintained, and they coexist. SwiftVLC is
not a fork of VLCKit or a replacement for it; it's a different set of
trade-offs aimed at a different generation of Swift.
