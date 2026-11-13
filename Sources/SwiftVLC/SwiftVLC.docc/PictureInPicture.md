# Picture-in-Picture

Float a miniature player above other apps.

## Platform support

Picture-in-Picture is stable public API on **iOS only**. SwiftVLC also
compiles the PiP wrapper on macOS, where ``PiPVideoView`` hosts libVLC's
drawable for inline playback but ``PiPController/isPossible`` stays
`false`: the only working macOS backend reparents that drawable through
Apple's private `PIP.framework`, so it ships behind the `PrivateMacOSPiP`
SPI described under **macOS and the private SPI** below. ``PiPController``
and ``PiPVideoView`` are not compiled on tvOS or visionOS; tvOS has no PiP
API and uses its system player UI for background playback instead.

On the iOS Simulator SwiftVLC reports PiP as unavailable, because
simulator sample-buffer PiP can reach `isPictureInPictureActive` while
rendering a black window. **Verify PiP on a physical device.** A
simulator run proves nothing about whether frames reach the system PiP
window.

## Using PiPVideoView

``PiPVideoView`` replaces ``VideoView`` and configures the PiP-capable
surface for you. On iOS it attaches libVLC's native drawable and
implements libVLC's Picture in Picture selectors; the bundled video output
renders inline into that drawable and owns the system
`AVPictureInPictureController`. SwiftVLC receives that controller only for
control and observable state.

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

The `controller` binding is filled in once the backing view is created —
not during `View` initialization — and tracks the view's lifetime
afterwards.

Use the controller for PiP *control and state*: ``PiPController/toggle()``,
``PiPController/isPossible``, ``PiPController/isActive``. Do **not** reach
for ``PiPController/layer`` here. ``PiPVideoView`` renders through libVLC's
native drawable, so that `AVSampleBufferDisplayLayer` is not the on-screen
surface and changing it (`videoGravity`, for instance) does nothing. The
layer is the rendering surface only when you construct ``PiPController``
yourself.

Pass `startsAutomaticallyFromInline: false` when video must never escape
to an OS-owned window on backgrounding — parental controls, kiosk modes,
watch-time policies. The value is captured when the backing view is built,
so changing it on a later render does not reconfigure an existing view.

Your app must declare the audio background mode:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

### Same-player media replacement

When ``Player/load(_:)`` replaces media while native PiP is active,
SwiftVLC keeps the existing `AVPictureInPictureController` and rebinds its
content source to the successor video output, preserving the system PiP
window and its controller identity instead of reporting a stop followed by
a new start. The handoff is generation-scoped: an ordinary stop or view
teardown is not preserved, and stale callbacks from the predecessor cannot
control the successor.

The successor must publish a usable display layer within the native
backend's rebuild bound. Observe `PiPController.pipContinuityEvents`
(iOS only) for `PiPContinuityOutcome.rebuilding`, `.restored`, or
`.timedOut`. A timeout stops the retained AVKit controller cleanly rather
than leaving a frozen window, and readiness arriving later from the
expired controller is ignored; a fresh controller may still serve that
media generation on a later PiP start. Direct PiP rebuilds no
libVLC-owned controller and emits no continuity events.

### Subtitles and OSD in the PiP window

The native iOS route includes VLC-rendered text, styled and bitmap
subtitles, forced subpictures, and OSD regions in the system PiP video.
While PiP is presenting and a subpicture exists, the video output
composites the immutable VLC region snapshot into a same-format pixel
buffer before AVKit receives it, preserving the decoder's pixel format,
dimensions, color and HDR attachments, clean aperture, pixel aspect ratio,
and sample timing. With no active region, playback stays on the zero-copy
path; inline playback keeps using VLC's sibling overlay view. PiP entry,
failed entry, paused subtitle changes, and inline restoration each enqueue
at most one immediate refresh sample, so they do not wait for the next
decoded frame.

``PiPController/overlaySupport`` reports
``PiPOverlaySupport/composited-enum.case`` for every bundled backend when
the matching engine artifact is linked, and
``PiPOverlaySupport/unavailable-enum.case`` for the native iOS backend
when a stale local engine predating this compositor is used. Visual
quality, subtitle timing, and CPU/GPU cost still need device evidence for
your own media matrix.

## Audio session (iOS)

PiP requires a playback-category audio session. ``PiPController`` does not
touch the process session when constructed: configuration and activation
are deferred until ``PiPController/start()`` or the first active-playback
signal, when the Player takes one opaque lease from the same native broker
libVLC's AudioUnit and sample-buffer outputs use. That broker serializes
`.playback` / `.moviePlayback` configuration, activation, owner counting,
and final deactivation across every Player, so a transient PiP controller
cannot deactivate another output. Building an idle view changes neither
category nor audio focus.

Each ``Player`` owns one audio-session disruption subscription whether or
not a PiP controller exists. A live managed controller receives those
signals as the session-policy handler; audio-only and ordinary video
playback use the same player-level transport fallback, which avoids both a
no-PiP blind spot and duplicate reactions while view reconstruction
briefly leaves two controllers alive.

The managed path handles interruptions, device lock, and app lifecycle:

- A **route loss** always pauses and clears playback intent, so audio
  cannot jump unexpectedly to the speaker.
- **Lock or backgrounding without an active PiP window** pauses native
  playback while preserving intent, releases audio focus, and resumes only
  that exact library-issued pause after a successful foreground
  activation. Backgrounding waits one second for automatic PiP to become
  active; if PiP stops while the app stays backgrounded, playback is
  suspended immediately.
- **Overlapping lifecycle and media-services suspensions** are tracked
  separately, so neither recovery signal can resume playback while the
  other disruption remains.
- A **media-services reset** is a stronger boundary: SwiftVLC invalidates
  the broker lease, rebuilds the invalidated native audio objects,
  installs a Player-owned playback quarantine, and waits for a new Play or
  Resume before configuring, activating, and restarting output. The
  quarantine survives PiP-controller reconstruction, retires pre-reset
  resume work, and rejects late native opening, buffering, or playing
  events as user permission. Intent that existed before the reset is never
  permission to restart.

To own audio-session configuration yourself, create the player's
``VLCInstance`` with
`appleAudioSessionPolicy: .applicationManaged`. In that mode neither
SwiftVLC nor bundled libVLC changes category, mode, preferred format, or
activation state. SwiftVLC still observes route loss and media-services
reset, because pausing VLC is a transport safety rule rather than an
`AVAudioSession` mutation, and Apple requires a new user action after a
reset before playback restarts.

The deprecated `PiPVideoView(..., managesAudioSession:)` overload stays
source- and behavior-compatible with SwiftVLC 1.0: its Boolean controls
only the PiP controller. It cannot reconfigure the Player's immutable
instance or make bundled libVLC audio outputs application-managed. Migrate
an explicit `false` to an `.applicationManaged` ``VLCInstance``.

## Using PiPController directly

Construct ``PiPController`` yourself only to place SwiftVLC's sample-buffer
video layer into a non-SwiftUI view hierarchy, or when your layout needs
more control than ``PiPVideoView`` offers:

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

``PiPStartResult/accepted`` means only that SwiftVLC issued the backend
request; AVKit may still reject it asynchronously. Consume
``PiPController/pipEventEnvelopes`` when callbacks can outlive a media
change or controller reconstruction: each envelope carries the media and
controller generation that owns the lifecycle and an extensible
``PiPEventEnvelope/stopCause``. ``PiPController/pipEvents`` is the
unattributed version-1 compatibility stream, where programmatic and
controller-replacement stops keep their historical
``PiPStopReason/unknown``.

PiP pause requests can be deferred while libVLC is opening or buffering.
``PiPController/deferredPauseOutcome`` is `nil` while an attempt is in
flight, then ``PiPController/DeferredPauseOutcome/issued`` when libVLC
accepts the pause, ``PiPController/DeferredPauseOutcome/cancelled`` when
the request is superseded, and
``PiPController/DeferredPauseOutcome/rejected`` when the input stays
unpausable through the bounded retry window. A rejection also restores
active playback intent, keeping observable controls consistent with
playback that is in fact continuing.

### Limits of the direct path

- ``PiPController/layer`` uses `videoGravity = .resizeAspect`. Size the
  parent view to the shape you want.
- The source picture is always delivered at its own aspect.
  ``Player/aspectRatio`` keeps a forced ``AspectRatio/ratio(_:_:)`` as you
  set it, but the ratio is not applied while a directly constructed
  ``PiPController`` renders the player; it takes effect again once that
  controller is released and the player renders into a view.
- The renderer asks libVLC for 8-bit BGRA frames and converts through an
  SDR RGB path when AVKit requests resized output. HDR and wide-color
  metadata are not preserved.
- On macOS this path may report system support, but it is not the
  recommended production path: it can crop video incorrectly on supported
  macOS releases.

### Playback ranges and live media

The direct route distinguishes three AVKit playback-range states:

- No loaded media gives an invalid range, because there is no content.
- Loaded media with no positive native duration gives an indefinite range
  with positive-infinite duration, so live playback can render before a
  duration is known.
- A positive native duration gives a finite range of that length.

Media, length, and seekability event payloads invalidate AVKit's playback
state so it re-queries the current native media handle. SwiftVLC uses the
event payload rather than a possibly stale ``Player`` property, because the
player and PiP observers consume independent event streams. Seekability
also keeps AVKit's `requiresLinearPlayback` synchronized on both iOS
routes. A successor controller adopting a preserved native attachment
re-samples current seekability under the backend's owner and
attachment-generation checks, covering events that arrived while no
controller owned the backend; playback-state transitions provide a
conservative fallback invalidation.

## macOS and the private SPI

The public AVKit sample-buffer path on macOS mirrors video through a
`CALayerHost` that, on the macOS releases SwiftVLC supports, crops to 1:1
instead of scaling into the PiP panel. Rather than ship a misleading
public switch for a private framework, the native macOS backend is
unavailable by default: ``PiPController/isPossible`` is `false` and
``PiPController/start()`` is a no-op for it. iOS is unaffected.

Non-App-Store distributions that deliberately accept private-framework
risk can opt in through the `PrivateMacOSPiP` SPI, which reparents the
drawable through `PIP.framework`. The panel then takes the picture's
shape rather than the host view's, and follows it when the shape changes —
a new playlist item, an adaptive stream, or a newly forced
``Player/aspectRatio``. That SPI sits outside the stable public API and the
semantic-versioning contract, and may change without a major release.

If you opt in, do not hand the ``VLCInstance`` an argument list that
disables or redirects video output: `--no-video`,
`--force-darwin-legacy-display`, or a `--vout` other than
`samplebufferdisplay` each stop the PiP-ready path. ``VLCInstance/defaultArguments``
sets none of those; append your own options to it rather than replacing it.

## Release qualification diagnostics

SwiftVLC's `Qualification` SPI exposes a pollable direct-PiP clock sample
and a lossless stream of control-timebase corrections. It captures the
polled libVLC media clock, a second native media-clock sample taken
synchronously at the decoded-frame display callback, the control-timebase
value and rate, delivered sample timestamp, frame counters, drop count,
generation, and each timebase write. It deliberately does **not** label
either media-clock sample as an audio presentation timestamp: release
qualification must pair the capture with an audio/video measurement and an
AVPlayer baseline recorded on the same fixture and physical device.

`Qualification` is test infrastructure, not stable public API, and may
change without a major-version release.

## Pitfalls

- **Never mix rendering paths.** A player attached to direct
  ``PiPController`` sample-buffer rendering cannot also back a
  ``VideoView``. ``PiPVideoView`` uses libVLC's native drawable path and
  owns the active video output for the view's lifetime.
- **Put the PiP surface on screen before calling ``Player/play()``.**
  libVLC creates the native PiP controller after the visible drawable's
  video output opens.
- **Do not wait for a duration before showing live PiP.** Unknown duration
  is reported to AVKit as indefinite content, not as an empty or fabricated
  finite range.

## Topics

### Views and controllers
- ``PiPVideoView``
- ``PiPController``

### State
- ``PiPController/isPossible``
- ``PiPController/isActive``
- ``PiPController/layer``
- ``PiPController/overlaySupport``
- ``PiPController/deferredPauseOutcome``
- ``PiPController/pipEventEnvelopes``
- ``PiPController/pipEvents``
- ``PiPController/pipSnapshots``
- ``PiPEventEnvelope``
- ``PiPStopCause``
- ``PiPStopReason``
- ``PiPOverlaySupport``

### Control
- ``PiPController/start()``
- ``PiPController/requestStart()``
- ``PiPController/stop()``
- ``PiPController/toggle()``
- ``PiPController/toggleReportingStartResult()``
- ``PiPStartResult``
