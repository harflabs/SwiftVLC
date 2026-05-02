# Displaying video

Render frames to a SwiftUI view, control aspect ratio, and understand
when to choose ``VideoView`` vs ``PiPVideoView``.

## The default: VideoView

``VideoView`` is a `UIViewRepresentable` / `NSViewRepresentable` that
hands libVLC a drawable surface. For most apps it's all you need:

```swift
VideoView(player)
    .frame(maxWidth: .infinity)
    .aspectRatio(16/9, contentMode: .fit)
```

A single player can back multiple views, but only one renders at a
time. libVLC moves its native rendering subview onto whichever
`VideoView` was most recently attached.

## Aspect ratio

Set ``Player/aspectRatio`` to shape the output:

```swift
player.aspectRatio = .default           // letterbox/pillarbox to fit
player.aspectRatio = .ratio(16, 9)      // force 16:9
player.aspectRatio = .fill              // cover the display; may crop
```

| Case | Behavior |
|---|---|
| ``AspectRatio/default`` | Preserve the source AR, fit into the smaller dimension |
| ``AspectRatio/ratio(_:_:)`` | Force a specific AR |
| ``AspectRatio/fill`` | Fit to the larger dimension (crop as needed) |

## When to use PiPVideoView instead

For Picture-in-Picture on iOS or macOS, use ``PiPVideoView`` in place
of ``VideoView``. The two should not share a player. iOS routes frames
through SwiftVLC's sample-buffer pipeline; macOS hands libVLC a native
drawable and moves that same view into the system PiP presenter, so PiP
controls and timing stay attached to VLC's own video output without the
AVKit sample-buffer mirror cropping path.

On macOS, keep the default ``VLCInstance`` arguments for players that
use PiP. The default keeps VLC's Apple sample-buffer display available
for inline playback, while ``PiPVideoView`` moves the full native
drawable container into the system PiP presenter so video and subtitles
stay together.

See <doc:PictureInPicture> for the complete setup.

## Taking a snapshot

Write the current video frame to disk as PNG:

```swift
try player.takeSnapshot(
    to: "/tmp/frame.png",
    width: 1920,        // pass 0 to derive from aspect ratio
    height: 0
)
```

The file is always PNG regardless of the path extension.

## Overlays

Add text, an image, or color adjustments through scoped accessors on
the player. They're `~Copyable` and `~Escapable`, so the compiler
prevents you from storing a reference that outlives the player.

```swift
player.withMarquee { m in
    m.isEnabled = true
    m.setText("LIVE")
    m.fontSize = 32
}
```

See <doc:VideoOverlays> for marquee, logo, video adjustments, and
360/VR viewpoint.

## Topics

### Views
- ``VideoView``
- ``PiPVideoView``

### Aspect
- ``AspectRatio``
- ``Player/aspectRatio``

### Snapshot
- ``Player/takeSnapshot(to:width:height:)``

### Overlays
- ``Player/withMarquee(_:)``
- ``Player/withLogo(_:)``
- ``Player/withAdjustments(_:)``
- ``Marquee``
- ``Logo``
- ``VideoAdjustments``
