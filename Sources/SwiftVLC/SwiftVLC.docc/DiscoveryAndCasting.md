# Discovery and casting

Find media and renderer devices through libVLC discovery services.

## Discovering media sources

``MediaDiscoverer`` wraps a named libVLC service. Depending on the
bundled plugins and host platform, services may include UPnP, SMB,
local directories, or podcasts. List the available services, then start
one:

```swift
let services = MediaDiscoverer.availableServices(category: .lan)
guard let upnp = services.first(where: { $0.name == "upnp" }) else { return }

let discoverer = try MediaDiscoverer(name: upnp.name)
try discoverer.start()

try? await Task.sleep(for: .seconds(2))
if let list = discoverer.mediaList {
    for i in 0..<list.count {
        print(list[i]?.mrl ?? "?")
    }
}
```

Categories:

| ``DiscoveryCategory`` | What it finds |
|---|---|
| `.devices` | Physical devices (portable music players, disc drives) |
| `.lan` | LAN discoverers such as UPnP, SMB, SAP, or Bonjour when available |
| `.podcasts` | Podcast directories |
| `.localDirectories` | System Music/Video/Pictures folders |

## Casting to a renderer

``RendererDiscoverer`` discovers renderer devices exposed by libVLC's
renderer-discovery plugins. It emits events through an `AsyncStream`, so
apps can react as soon as a renderer appears or disappears:

```swift
let services = RendererDiscoverer.availableServices()
guard let service = services.first else { return }
let player = Player()
try player.play(url: mediaURL)

let discoverer = try RendererDiscoverer(name: service.name)
try discoverer.start()

for await event in discoverer.events {
    switch event {
    case .itemAdded(let renderer):
        print("Found", renderer.name, renderer.type)
        do {
            try await player.recast(to: renderer)
        } catch {
            print("Cast failed:", error)
        }
    case .itemDeleted(let renderer):
        print("Lost", renderer.name)
    }
}
```

libVLC applies renderer selection before a native media player's first
play. SwiftVLC preserves that rule at the public API boundary: use
``Player/setRenderer(_:)`` before starting playback on a ``Player``. To
retarget after playback has started, await ``Player/recast(to:)``. It
keeps the same ``Player`` while replacing the native handle and restarting
the current media. Pass `nil` to `recast(to:)` to return active playback
to local output, or to `setRenderer(_:)` before the first play.

## Inspecting a renderer

``RendererItem`` exposes the device's display name, type, and
capabilities:

```swift
if renderer.canVideo && renderer.type == "chromecast" {
    // OK to cast video
}
```

## Topics

### Media discovery
- ``MediaDiscoverer``
- ``DiscoveryService``
- ``DiscoveryCategory``

### Renderer discovery
- ``RendererDiscoverer``
- ``RendererItem``
- ``RendererEvent``
- ``RendererService``

### Controlling output
- ``Player/setRenderer(_:)``
- ``Player/recast(to:)``
