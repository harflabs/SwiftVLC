# Picture-in-Picture

Float a miniature player above other apps on iOS, or into the system
PiP on macOS.

## Using PiPVideoView

``PiPVideoView`` replaces ``VideoView`` and configures AVKit's PiP
controller on your behalf.

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
don't support sample-buffer PiP (e.g. tvOS).

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

Instantiate ``PiPController`` yourself when placing the video into a
non-SwiftUI view hierarchy, or when your layout needs more control
than ``PiPVideoView`` offers:

```swift
let controller = PiPController(player: player)
container.layer.addSublayer(controller.layer)
controller.start()
```

``PiPController/layer`` uses `videoGravity = .resizeAspect`. Size the
parent view to the aspect ratio you want.

## Common pitfalls

- **Never mix rendering paths.** A player attached to ``PiPController``
  cannot also back a ``VideoView``. Frames flow through vmem callbacks
  into an `AVSampleBufferDisplayLayer`; libVLC's `set_nsobject`
  drawable is disabled on the same player.
- **Add the layer to a view before calling `player.play()`.** PiP
  recognizes the sample-buffer layer as a valid content source only
  once it's on screen.

## Platform availability

Picture-in-Picture is available on iOS and macOS. tvOS has no PiP API
(its system player UI handles background playback instead), so
``PiPController`` and ``PiPVideoView`` are not compiled on that
platform.

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
