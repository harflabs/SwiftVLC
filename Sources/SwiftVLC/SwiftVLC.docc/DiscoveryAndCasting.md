# Discovery and casting

Find media on the local network, and cast to Chromecast or AirPlay
receivers.

## Discovering media sources

``MediaDiscoverer`` wraps a named libVLC service, such as UPnP, SMB,
local directories, or podcasts. List the available services, then
start one:

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
| `.lan` | UPnP, SMB, SAP, Bonjour |
| `.podcasts` | Podcast directories |
| `.localDirectories` | System Music/Video/Pictures folders |

## Casting to a renderer

``RendererDiscoverer`` discovers Chromecast, AirPlay, and UPnP/DLNA
renderers. It emits events through an `AsyncStream`, so apps can react
as soon as a renderer appears or disappears:

```swift
let services = RendererDiscoverer.availableServices()
guard let service = services.first else { return }

let discoverer = try RendererDiscoverer(name: service.name)
try discoverer.start()

for await event in discoverer.events {
    switch event {
    case .itemAdded(let renderer):
        print("Found", renderer.name, renderer.type)
        try? player.setRenderer(renderer)
    case .itemDeleted(let renderer):
        print("Lost", renderer.name)
    }
}
```

Pass `nil` to ``Player/setRenderer(_:)`` to revert to local playback.

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
