# Picture-in-Picture

Float a miniature player above other apps on iOS, or into the system
PiP on macOS.

## Using PiPVideoView

``PiPVideoView`` replaces ``VideoView`` and configures the platform PiP
surface on your behalf. On iOS it uses SwiftVLC's AVKit sample-buffer
path. On macOS it keeps libVLC's native drawable as the only video surface
and moves that drawable into the system PiP presenter. That keeps video,
audio, playback intent, and time on the same VLC timeline while avoiding
macOS's broken AVKit sample-buffer mirror path.

SwiftVLC's default macOS ``VLCInstance`` arguments leave VLC's Apple
sample-buffer display enabled for normal inline playback. ``PiPVideoView``
owns a native drawable container and moves that whole container into the
system PiP presenter, so subtitle and video layers remain together during
the transition. If you create a custom ``VLCInstance`` for a macOS player
that will enter PiP, include ``VLCInstance/defaultArguments`` in your
custom argument list.

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
don't expose SwiftVLC's PiP APIs (e.g. tvOS and visionOS).

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

Instantiate ``PiPController`` yourself when placing SwiftVLC's
sample-buffer video layer into a non-SwiftUI view hierarchy, or when
your layout needs more control than ``PiPVideoView`` offers:

```swift
let controller = PiPController(player: player)
container.layer.addSublayer(controller.layer)
controller.start()
```

``PiPController/layer`` uses `videoGravity = .resizeAspect`. Size the
parent view to the aspect ratio you want. On macOS, prefer
``PiPVideoView`` unless you are intentionally using the direct
sample-buffer pipeline.

## Common pitfalls

- **Never mix rendering paths.** A player attached to direct
  ``PiPController`` sample-buffer rendering cannot also back a
  ``VideoView``. ``PiPVideoView`` owns the active video output for the
  lifetime of the view.
- **Put the PiP surface on screen before calling `player.play()`.**
  AVKit recognizes the PiP source only once the surface is visible and
  receiving frames.
- **Keep the macOS PiP-safe VLC defaults.** Passing a completely custom
  ``VLCInstance`` argument list on macOS can disable video output or force
  an unsupported vout. Start from ``VLCInstance/defaultArguments`` and
  append your own options instead.

## macOS implementation notes

SwiftVLC's macOS PiP path can use Apple's private `PIPViewController`
class, loaded dynamically from `/System/Library/PrivateFrameworks/PIP.framework`.
It is disabled by default because private frameworks are not public API.

The reason: AVKit's public sample-buffer PiP API mirrors video frames
through a `CALayerHost`, which on macOS releases SwiftVLC supports
crops to 1:1 instead of scaling into the PiP panel. Without the
private API, macOS PiP either looks broken or has to be disabled
outright. The private API does what consumers expect — moves the
existing VLC drawable view into the floating PiP window, keeping
video, audio, subtitles, and time on the same VLC timeline.

If your distribution channel accepts private API use, opt in at app
launch:

```swift
import SwiftVLC

@main
struct MyApp: App {
    init() {
        PiPController.allowsPrivateMacOSAPI = true
    }
    var body: some Scene { ... }
}
```

With the default flag value of `false`:
- ``PiPController/isPossible`` returns `false` on macOS.
- ``PiPController/start()`` is a no-op.
- iOS PiP is unaffected — iOS uses only public AVKit.

If `PIP.framework` ever stops loading (private API removed by Apple),
``PiPController/isPossible`` returns `false` automatically — no crash,
no fallback to the broken AVKit path.

## Platform availability

Picture-in-Picture is available on iOS and macOS. tvOS has no PiP API
(its system player UI handles background playback instead), and
SwiftVLC does not compile the PiP wrapper on visionOS.
``PiPController`` and ``PiPVideoView`` are not compiled on those
platforms.

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
