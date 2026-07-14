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

### Native PiP subtitle limitation

The bundled native iOS PiP route does not currently include VLC-rendered
subtitles, bitmap subpictures, or on-screen-display regions in the system PiP
video. VLC draws those regions into a sibling overlay view for inline playback,
while AVKit receives only the video sample-buffer layer. Core Animation
sublayers and sibling views are not composited into that content source.

Supporting subtitles without degrading the zero-copy and HDR paths requires a
separate, same-format burn-in stage before sample enqueue. That compositor is
not part of SwiftVLC today. Do not rely on an inline subtitle appearing in the
system PiP window; validate the exact subtitle behavior your app requires on a
physical device.

## Audio session (iOS only)

PiP requires a playback-category audio session. ``PiPController``
sets the `.playback` category automatically when it is constructed, but
direct controller construction and native-view construction for an inactive
Player deliberately do not activate the session. Merely building an idle view
therefore does not take audio focus.

`setActive(true)` is deferred until ``PiPController/start()`` or the
first active-playback signal. When a native iOS view adopts an already-playing
Player, SwiftVLC activates before publishing the successor controller as the
native backend owner; libVLC's AVKit controller may otherwise auto-start
without SwiftVLC receiving a will-start callback. The direct route retries at
will-start, and the native route retries when it observes did-start. If
activation fails transiently, SwiftVLC leaves it pending for either fallback.

Pass `managesAudioSession: false` to ``PiPVideoView`` when your app owns
audio-session policy. In that mode SwiftVLC neither changes the category
nor activates the shared session.

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
controller.start()
```

``PiPController/layer`` uses `videoGravity = .resizeAspect`. Size the
parent view to the aspect ratio you want. On macOS, the direct public
sample-buffer path may reflect system support but is not the recommended
production path because it can crop video incorrectly on supported macOS
releases.

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
- **Native PiP does not currently carry VLC's subtitle overlay.** Inline
  subtitle visibility is not evidence that the same region reaches AVKit's
  system PiP video.
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

### Control
- ``PiPController/start()``
- ``PiPController/stop()``
- ``PiPController/toggle()``
