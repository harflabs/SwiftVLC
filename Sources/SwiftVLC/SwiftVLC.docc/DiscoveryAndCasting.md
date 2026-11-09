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
let events = discoverer.events
try discoverer.start()

for await event in events {
    switch event {
    case .itemAdded(let renderer):
        print("Found", renderer.name, renderer.type)
        do {
            let outcome = try await player.recastAndWaitForOutcome(to: renderer)
            guard outcome.isSettled else {
                print("Cast did not settle:", outcome)
                continue
            }
        } catch {
            print("Cast failed:", error)
        }
    case .itemDeleted(let renderer):
        print("Lost", renderer.name)
    }
}
```

Obtaining the stream before `start()` makes the lifecycle explicit, but it is
not required for correctness. A new ``RendererDiscoverer/events`` stream first
replays `.itemAdded` for the discoverer's current renderer inventory and then
delivers later transitions. This covers renderer callbacks that libVLC can emit
synchronously inside `start()`, as well as a UI that begins observing after
discovery is already running. Stopping discovery clears that inventory and
delivers matching `.itemDeleted` transitions to existing streams, so restarting
cannot resurrect renderer items owned by the retired native discovery module.

libVLC applies renderer selection before a native media player's first
play. SwiftVLC preserves that rule at the public API boundary: use
``Player/setRenderer(_:)`` before starting playback on a ``Player``. To
retarget after playback has started, await
``Player/recastAndWaitForOutcome(to:)``. It keeps the same ``Player`` while
replacing the native handle and restarting the current media. Pass `nil` to
return active playback to local output, or to `setRenderer(_:)` before the
first play. ``Player/recast(to:)`` remains the version-1-compatible action
when the terminal outcome is intentionally ignored.
Inspect the returned ``RecastOutcome``: only `.settled` means the replacement
and requested transport restoration completed. A nonthrowing timeout, failure,
cancellation, or superseding operation must not be presented as a successful
cast.

For a media generation already staged for a deferred fresh handle, recast only
updates the renderer configuration; it does not spend another generation or
start playback. The same no-autoplay rule applies to a previously used handle
that is now idle, stopped, or failed: the renderer is staged and the next
explicit `play()` creates the fresh handle. Active opening, buffering, and
playing sessions are replaced and restarted. A paused session is restarted and
does not settle until its pause is acknowledged.

Position and track restoration are local wrapper guarantees, not receiver
acknowledgements. Stable track ids are preferred exactly; an adaptive stream's
per-session ids (``Track/isIDStable`` is `false`) are never trusted across
sessions. Metadata fallback considers only tracks of the same type and codec and
is used only when language/name identifies one unique candidate, so discovery
order can never choose between ambiguous renditions. A `.settled` result means SwiftVLC's
replacement transaction completed. It does **not** prove that a physical
receiver rendered audio/video or acknowledged a command; qualify that behavior
with the real-device release checklist.

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
- ``Player/recastAndWaitForOutcome(to:)``
