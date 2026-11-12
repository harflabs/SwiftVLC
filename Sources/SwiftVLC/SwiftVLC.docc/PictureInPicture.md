# Picture-in-Picture

Float a miniature player above other apps on iOS. macOS PiP is compiled
in but unavailable through the stable public API by default because the
working native backend uses private Apple framework symbols.

## Using PiPVideoView

``PiPVideoView`` replaces ``VideoView`` and configures the PiP-capable
surface on your behalf. On iOS it attaches libVLC's native drawable and
implements libVLC's Picture in Picture selectors. The bundled iOS video
output renders inline into that drawable and owns the system
`AVPictureInPictureController`; SwiftVLC receives the native controller
only for control and observable state. ``PiPVideoView`` does not place
``PiPController/layer`` in its view hierarchy.

On macOS, ``PiPVideoView`` still hosts libVLC's native drawable for
inline playback. Its native PiP start path remains unavailable unless
your build opts into SwiftVLC's `PrivateMacOSPiP` SPI, because the
working backend reparents that drawable through Apple's private
`PIP.framework`.

```swift
struct PlayerScreen: View {
    @State private var player = Player()
    @State private var pip: PiPController?

    var body: some View {
        VStack {
            PiPVideoView(player, controller: $pip)
                .aspectRatio(16/9, contentMode: .fit)

            Button("Picture in Picture") { pip?.toggle() }
                .disabled(pip?.isPossible != true)
        }
    }
}
```

The `controller` binding is populated during view construction and
stays in sync with the view's lifetime. On macOS the binding is non-`nil`,
but ``PiPController/isPossible`` remains `false` unless the SPI native
backend is enabled and available at runtime. SwiftVLC's PiP types are not
compiled on tvOS or visionOS.

Use the binding's controller for PiP *control and state*
(``PiPController/toggle()``, ``PiPController/isPossible``,
``PiPController/isActive``). Do **not** reach for its
``PiPController/layer``: ``PiPVideoView`` renders through libVLC's native
drawable on iOS, so the controller's `AVSampleBufferDisplayLayer` is not
the on-screen surface and adjusting it (e.g. `videoGravity`) has no
effect. ``PiPController/layer`` is the rendering surface only when you
instantiate ``PiPController`` yourself and host the layer directly.

On iOS Simulator, SwiftVLC reports native PiP as unavailable. Simulator
AVSampleBufferDisplayLayer PiP can reach `isPictureInPictureActive` while
rendering a black system PiP window, so validate iOS PiP rendering on
a physical device. Simulator success is not evidence that frames reach
the system PiP window.

### Same-player media replacement

When ``Player/load(_:)`` replaces media while native iOS PiP is active,
SwiftVLC keeps the existing `AVPictureInPictureController` and rebinds its
content source to the successor video output. This preserves the system PiP
window and its controller identity instead of reporting a stop followed by a
new start. The handoff is generation-scoped: ordinary stop or view teardown is
not preserved, and stale callbacks from the predecessor cannot control the
successor.

The successor has three seconds to publish a usable display layer. Observe
`PiPController.pipContinuityEvents` for
`PiPContinuityOutcome.rebuilding`, `PiPContinuityOutcome.restored`, or
`PiPContinuityOutcome.timedOut`. A timeout stops the retained AVKit
controller cleanly rather than leaving a frozen PiP window. Direct PiP does
not rebuild a libVLC-owned controller and therefore emits no continuity
events. Readiness arriving later from the expired controller is ignored; a
fresh controller may still serve that same media generation on a subsequent
PiP start.

### Native PiP subtitles and OSD

The bundled native iOS PiP route includes VLC-rendered text, styled and bitmap
subtitles, forced subpictures, and on-screen-display regions in the system PiP
video. While system PiP is presenting and a subpicture exists, the native video
output composites the immutable VLC region snapshot into a same-format pixel
buffer before AVKit receives it. With no active region, playback stays on the
zero-copy video path; inline playback continues to use VLC's sibling overlay
view.

The compositor preserves the decoder's pixel format, dimensions, color and HDR
attachments, clean aperture, pixel aspect ratio, and sample timing. PiP entry,
failed entry, paused subtitle changes, and inline restoration enqueue at most
one immediate refresh sample, so they do not wait for the next decoded frame.

``PiPController/overlaySupport`` reports
``PiPOverlaySupport/composited-enum.case`` for every bundled backend when the matching
engine artifact is linked. It reports ``PiPOverlaySupport/unavailable-enum.case`` for the
native iOS backend if a stale local engine predating this compositor is used.
Physical-device qualification is still the authority for visual quality,
subtitle timing, and CPU/GPU impact on the exact hardware and formats your app
supports.

## Audio session (iOS only)

PiP requires a playback-category audio session. ``PiPController``
does not touch the process session when it is constructed. Configuration and
activation are deferred together until ``PiPController/start()`` or the first
active-playback signal, when the Player acquires one opaque lease from the
same native broker used by libVLC's AudioUnit and sample-buffer audio outputs.
That broker serializes `.playback` / `.moviePlayback` configuration,
activation, owner counting, and final deactivation across every Player, so a
transient PiP controller cannot deactivate another output. Merely building an
idle view therefore neither changes category nor takes audio focus.

When a native iOS view adopts an already-playing Player, SwiftVLC acquires its
lease before publishing the successor controller as the native backend owner;
libVLC's AVKit controller may otherwise auto-start without SwiftVLC receiving
a will-start callback. The direct route retries at will-start, and the native
route retries when it observes did-start. A failed acquisition retains no
Swift latch, so either signal can retry. Native-handle replacement acquires the
successor lease before releasing the predecessor, avoiding a zero-owner focus
gap.

Each ``Player`` owns one audio-session disruption subscription, independent of
whether a PiP controller exists. A live managed PiP controller receives those
signals as the session-policy handler; audio-only and ordinary video playback
use the same player-level transport fallback. This avoids both a no-PiP blind
spot and duplicate reactions when view reconstruction briefly leaves multiple
controllers alive.

The managed path handles audio interruptions, device lock, and app lifecycle.
A route loss always pauses and changes playback intent so audio cannot jump
unexpectedly to the speaker.
Device lock or backgrounding without an active PiP window instead pauses native
playback while preserving the user's intent, releases audio focus, and resumes
only that exact library-issued pause after a successful foreground activation.
Background handling waits one second for automatic PiP to become active; if PiP
stops while the app remains backgrounded, playback is suspended immediately.
Overlapping lifecycle and media-services suspensions are tracked separately, so
neither recovery signal can resume playback while the other disruption remains.
A media-services reset is a stronger boundary: SwiftVLC invalidates the old
broker lease, rebuilds invalidated native audio objects, installs a
Player-owned playback quarantine, and waits for a new Play or Resume action
before configuring, activating, and restarting output. The
quarantine survives PiP-controller reconstruction, retires pre-reset resume
work, and rejects late native opening, buffering, or playing events as user
permission. It never treats the intent that existed before the reset as
permission to restart playback.

Create the player's ``VLCInstance`` with
`appleAudioSessionPolicy: .applicationManaged` when your app owns audio-session
configuration and activation. In that mode neither SwiftVLC nor bundled libVLC
changes category, mode, preferred format, or activation state. SwiftVLC still
observes route loss and media-services reset because pausing VLC is a transport
safety rule, not an `AVAudioSession` mutation; after reset, Apple requires a
new user action before playback restarts.

The deprecated `PiPVideoView(..., managesAudioSession:)` overload remains
source- and behavior-compatible with SwiftVLC 1.0: its Boolean controls only
the PiP controller. It cannot reconfigure the Player's immutable instance or
make bundled libVLC audio outputs application-managed. Migrate an explicit
`false` to an `.applicationManaged` ``VLCInstance`` when the application needs
the complete process-session opt-out described above.

Your app must also declare background modes in its Info.plist:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

## Using PiPController directly

Instantiate ``PiPController`` yourself only when placing SwiftVLC's
public iOS sample-buffer video layer into a non-SwiftUI view hierarchy,
or when your layout needs more control than ``PiPVideoView`` offers:

```swift
let controller = PiPController(player: player)
container.layer.addSublayer(controller.layer)
switch controller.requestStart() {
case .accepted:
  // Observe pipEventEnvelopes for the attributed asynchronous outcome.
  break
case .noMedia, .notPossible, .backendUnavailable:
  // Keep or restore the inline presentation.
  break
}
```

A ``PiPStartResult/accepted`` result means only that SwiftVLC issued the
backend request. AVKit may still reject it asynchronously. Consume
``PiPController/pipEventEnvelopes`` when callbacks can outlive a media change
or controller reconstruction; each envelope carries the media and controller
generation that owns the lifecycle and an extensible
``PiPEventEnvelope/stopCause`` for stop events. ``PiPController/pipEvents``
remains the unattributed version-1 compatibility stream; programmatic and
controller-replacement stops retain its historical `.unknown` reason.

PiP pause requests can be deferred while libVLC is opening or buffering.
Observe ``PiPController/deferredPauseOutcome`` when your UI needs the terminal
result. It is `nil` while an attempt is in flight, becomes
``PiPController/DeferredPauseOutcome/issued`` when libVLC accepts the pause,
``PiPController/DeferredPauseOutcome/cancelled`` when the request is
superseded, and ``PiPController/DeferredPauseOutcome/rejected`` when the input
remains unpausable through the bounded retry window. A rejection also restores
active playback intent, keeping observable controls consistent with continuing
native playback.

``PiPController/layer`` uses `videoGravity = .resizeAspect`. Size the
parent view to the aspect ratio you want. On macOS, the direct public
sample-buffer path may reflect system support but is not the recommended
production path because it can crop video incorrectly on supported macOS
releases.

The direct path always delivers the source picture at its own aspect.
``Player/aspectRatio`` keeps a forced ``AspectRatio/ratio(_:_:)`` as you set
it, but the ratio is not applied while a directly constructed
``PiPController`` renders the player; it takes effect again once that
controller is released and the player renders into a view.

The direct renderer asks libVLC for 8-bit BGRA frames and uses an SDR RGB
conversion path when AVKit requests resized output. It does not preserve
HDR or wide-color metadata; use it only when that limitation is acceptable.

## Playback ranges and live media

The direct public sample-buffer route distinguishes three AVKit
playback-range states:

- No loaded media produces an invalid range because there is no content.
- Loaded media with no positive native duration produces an indefinite
  range with positive-infinite duration. Live playback can render before
  a duration is known.
- A positive native duration produces a finite range of that length.

Media, length, and seekability event payloads invalidate AVKit's playback
state so it re-queries the current native media handle. SwiftVLC uses the
event payload rather than a potentially stale ``Player`` property because
the player and PiP observers consume independent event streams. Seekability
also keeps AVKit's `requiresLinearPlayback` setting synchronized on both
iOS PiP routes. A successor controller adopting a preserved native attachment
also re-samples current seekability under the backend's owner and attachment-
generation checks, covering events that arrived while no controller owned the
backend. Playback-state transitions provide a conservative fallback
invalidation.

## Release qualification diagnostics

SwiftVLC's `Qualification` SPI exposes a pollable direct-PiP clock sample
and a lossless stream of control-timebase corrections. The device-validation
harness's Matrix I writes both to JSON Lines as they occur, so a multi-hour
run remains recoverable even if the app later terminates.

The capture includes the polled libVLC media clock, a second native media-clock
sample taken synchronously at the decoded-frame display callback, the
control-timebase value and rate, delivered sample timestamp, frame counters,
drop count, generation, and each timebase write. It deliberately does **not**
label either media-clock sample as an audio
presentation timestamp. Release qualification must pair the JSONL with an
audio/video measurement and an AVPlayer baseline recorded with the same
fixture and physical device.

`Qualification` is test infrastructure, not stable public API. It may change
without a major-version release.

## Common pitfalls

- **Never mix rendering paths.** A player attached to direct
  ``PiPController`` sample-buffer rendering cannot also back a
  ``VideoView``. ``PiPVideoView`` uses libVLC's native drawable path and
  owns the active video output for the lifetime of the view.
- **Put the PiP surface on screen before calling `player.play()`.**
  libVLC creates the native PiP controller after the visible drawable's
  video output opens.
- **Do not wait for a duration before showing live PiP.** A loaded input
  with an unknown duration is reported to AVKit as indefinite content,
  not as an empty or fabricated finite range.
- **Validate system PiP video on a physical iOS device.** Simulator PiP
  state can become active while its system window remains black.
- **Qualify overlays on the target device.** Native PiP composites active VLC
  subpictures into AVKit's sample buffers, but visual timing, HDR output, and
  performance still require physical-device evidence for your media matrix.
- **Keep the macOS PiP-safe VLC defaults if you opt into SPI.** Passing
  a completely custom ``VLCInstance`` argument list on macOS can disable
  video output or force an unsupported vout. Start from
  ``VLCInstance/defaultArguments`` and append your own options instead.

## macOS implementation notes

SwiftVLC does not expose private macOS PiP controls as stable public API.
The public AVKit sample-buffer PiP path mirrors video frames through a
`CALayerHost`, which on macOS releases SwiftVLC supports crops to 1:1
instead of scaling into the PiP panel. Rather than ship a misleading
public switch for a private framework, the native macOS PiP backend is
unavailable by default:

- ``PiPVideoView``'s macOS native backend reports
  ``PiPController/isPossible`` as `false`.
- ``PiPController/start()`` is a no-op for that native backend.
- iOS PiP is unaffected; libVLC's iOS drawable PiP path uses public AVKit.

Non-App-Store distributions that deliberately accept private framework
risk may opt in through SwiftVLC's `PrivateMacOSPiP` SPI. That SPI is
outside the stable public API and semantic-versioning contract. It may
change without a major-version release.

## Platform availability

Picture-in-Picture is available as stable public API on iOS. SwiftVLC
also compiles the PiP wrapper on macOS, but the native macOS PiP backend
is SPI-gated and unavailable by default. tvOS has no PiP API (its system
player UI handles background playback instead), and SwiftVLC does not
compile the PiP wrapper on visionOS. ``PiPController`` and
``PiPVideoView`` are not compiled on tvOS or visionOS.

## Topics

### Views and controllers
- ``PiPVideoView``
- ``PiPController``

### State
- ``PiPController/isPossible``
- ``PiPController/isActive``
- ``PiPController/layer``
- ``PiPController/deferredPauseOutcome``
- ``PiPController/pipEventEnvelopes``
- ``PiPController/pipSnapshots``

### Control
- ``PiPController/start()``
- ``PiPController/stop()``
- ``PiPController/toggle()``
