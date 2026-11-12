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
renderer-discovery plugins. The bundled libVLC ships two services, and they
find different kinds of device, so choose one by name rather than taking the
first entry of ``RendererDiscoverer/availableServices(instance:)``:

| Service name | Finds | Plays through |
|---|---|---|
| `Bonjour_renderer` | Chromecast and other Google Cast devices | libVLC's Chromecast output |
| `upnp_renderer` | UPnP/DLNA media renderers (many TVs and AV receivers) | libVLC's DLNA output |

`upnp_renderer` is listed first and never finds a Chromecast. The DLNA output
is present in the bundled libVLC, but SwiftVLC's cast qualification covers
Chromecast only; treat DLNA devices as unverified.

Bonjour discovery on iOS, tvOS, and visionOS needs two `Info.plist` entries.
Without them the system refuses the browse and discovery stays empty without
an error:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds Chromecast devices on your network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_googlecast._tcp</string>
</array>
```

The discoverer emits events through an `AsyncStream`, so apps can react as
soon as a renderer appears or disappears:

```swift
let player = Player()
try player.play(url: mediaURL)

// Chromecast devices are found by the Bonjour service only.
let discoverer = try RendererDiscoverer(name: "Bonjour_renderer")
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
acknowledgements. A track type that was turned off stays off on the new
session. Stable track ids are preferred exactly; an adaptive stream's
per-session ids (``Track/isIDStable`` is `false`) are never trusted across
sessions. Metadata fallback considers only tracks of the same type and codec and
is used only when language/name identifies one unique candidate, so discovery
order can never choose between ambiguous renditions. A `.settled` result means SwiftVLC's
replacement transaction completed. It does **not** prove that a physical
receiver rendered audio/video or acknowledged a command; qualify that behavior
with the real-device release checklist.

## Answering the Chromecast trust question

A cast does not connect until your app answers a question from libVLC. A
Chromecast authenticates its control connection with a device certificate that
no public certificate authority signs, so libVLC's TLS layer cannot validate it
and asks, through ``DialogHandler``, whether to continue. With no handler
registered, or with the question dismissed, the connection is refused: the
session ends in ``PlayerState/error`` and ``Player/recastAndWaitForOutcome(to:)``
returns ``RecastOutcome/failed``.

Register one ``DialogHandler`` for the instance before casting and accept the
question while your own cast is connecting.
``QuestionRequest/isCertificateTrustQuestion`` recognises it:

```swift
@MainActor
final class CastTrust {
    private let handler = DialogHandler(instance: .shared)
    private var task: Task<Void, Never>?
    /// Set this around your own cast attempts only.
    var isConnectingToCastDevice = false

    func start() {
        let dialogs = handler.dialogs
        task = Task { [weak self] in
            for await event in dialogs {
                guard let question = event.question else { continue }
                if
                    question.isCertificateTrustQuestion,
                    self?.isConnectingToCastDevice == true {
                    question.post(action: 1)
                } else {
                    question.dismiss()
                }
            }
        }
    }
}

let trust = CastTrust()
trust.start()

trust.isConnectingToCastDevice = true
let outcome = try await player.recastAndWaitForOutcome(to: renderer)
trust.isConnectingToCastDevice = false
```

Three things to know:

- libVLC blocks the connection until the question is answered, so always
  answer or dismiss every question you receive.
- The same question is raised for *any* TLS peer libVLC cannot validate,
  including an HTTPS stream with a self-signed certificate. SwiftVLC never
  accepts it on your behalf; scope acceptance to your cast flow as above, or
  show it to the user.
- The acceptance is remembered only for that one connection. The question
  comes back on every cast, including a recast to the same device.

libVLC can also ask a "Performance warning" question before it converts media
for a renderer. ``VLCInstance/defaultArguments`` turns that question off. It
only reaches your handler if you build an instance from a custom argument list
without `--sout-renderer-show-perf-warning=0`; in that case answer it with
action `1`, because libVLC leaves a declined cast unloaded while the player
still reports ``PlayerState/playing``.

## Known limits while casting

These describe libVLC's Chromecast output as bundled. They were measured
against a scripted Cast receiver, not inferred, and none of them surfaces as an
error on its own.

- **A receiver that cannot load fails slowly.** libVLC waits 30 seconds for a
  receiver to acknowledge each load, then retries, first as-is and then with
  video and audio conversion. A receiver that accepts the connection but never
  answers kept the player in ``PlayerState/playing`` with a frozen
  ``Player/currentTime`` for about two minutes before the session failed; one
  that rejects the load outright fails in under a second. Because
  ``Player/recastAndWaitForOutcome(to:)`` settles when libVLC starts the
  session, it can return ``RecastOutcome/settled`` before any of this. Treat a
  cast whose time has not advanced a few seconds after it settled as not yet
  playing.
- **A pause made on the receiver is not a state change.** When someone pauses
  with the TV remote or another Cast controller, ``Player/state`` stays
  ``PlayerState/playing`` and ``Player/currentTime`` stops advancing. The only
  signal is ``PlayerEvent/corked-enum.case``, followed by
  ``PlayerEvent/uncorked-enum.case`` when the receiver resumes. libVLC raises
  the same events for your own pause and resume, and after a seek made while
  paused it can leave the session corked with no matching uncork, so use them
  as a hint to re-read the transport rather than as a strict pair.
- **Volume and mute do not reach the receiver.** libVLC has no local audio
  output during a cast and does not forward volume to the device.
  ``Player/setAudioVolume(_:)`` throws ``VLCError/operationFailed(_:)`` while
  casting, and setting ``Player/isMuted`` changes the property without
  silencing anything. Leave volume to the receiver.
- **Choose the renderer before loading media.** ``Player/setRenderer(_:)``
  followed by ``Player/load(_:)`` or ``Player/play(url:)`` starts the cast
  directly. In the other order (load, then `setRenderer`, then play) libVLC
  opens the local audio and video outputs first and switches to the renderer
  a moment later. ``Player/recastAndWaitForOutcome(to:)`` is not affected.

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
