# Picture-in-Picture

Float a miniature player above other apps on iOS. macOS PiP is compiled
in but unavailable through the stable public API by default because the
working native backend uses private Apple framework symbols.

## Using PiPVideoView

``PiPVideoView`` replaces ``VideoView`` and configures the PiP-capable
surface on your behalf. On iOS it uses SwiftVLC's public AVKit
sample-buffer path.

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
stays in sync with the view's lifetime. It's `nil` on platforms that
don't expose SwiftVLC's PiP APIs (e.g. tvOS and visionOS). On macOS the
binding is non-`nil`, but ``PiPController/isPossible`` remains `false`
unless the SPI native backend is enabled and available at runtime.

## Audio session (iOS only)

PiP requires a playback-category audio session. ``PiPController``
configures one automatically on `init`:

```swift
try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
try? AVAudioSession.sharedInstance().setActive(true)
```

Your app must also declare background modes in its Info.plist:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

## Using PiPController directly

Instantiate ``PiPController`` yourself when placing SwiftVLC's public
iOS sample-buffer video layer into a non-SwiftUI view hierarchy, or when
your layout needs more control than ``PiPVideoView`` offers:

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

## Common pitfalls

- **Never mix rendering paths.** A player attached to direct
  ``PiPController`` sample-buffer rendering cannot also back a
  ``VideoView``. ``PiPVideoView`` owns the active video output for the
  lifetime of the view.
- **Put the PiP surface on screen before calling `player.play()`.**
  AVKit recognizes the PiP source only once the surface is visible and
  receiving frames.
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
- iOS PiP is unaffected — iOS uses only public AVKit.

Non-App-Store distributions that deliberately accept private framework
risk may opt in through SwiftVLC's `PrivateMacOSPiP` SPI. That SPI is
outside the stable public API contract and may change before `1.0`.

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
