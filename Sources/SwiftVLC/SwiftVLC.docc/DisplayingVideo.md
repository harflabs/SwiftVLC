# Displaying video

Render frames to a SwiftUI view and control the picture's shape.

## The default: VideoView

``VideoView`` is a `UIViewRepresentable` / `NSViewRepresentable` that
hands libVLC a drawable surface. For most apps it is all you need:

```swift
VideoView(player)
    .frame(maxWidth: .infinity)
    .aspectRatio(16/9, contentMode: .fit)
```

A single player can back several views, but only one renders at a time:
libVLC moves its native rendering subview onto whichever `VideoView` was
attached most recently.

## Aspect ratio

Set ``Player/aspectRatio`` to shape the output:

```swift
player.aspectRatio = .default           // letterbox/pillarbox to fit
player.aspectRatio = .ratio(16, 9)      // force 16:9, stretching the source
player.aspectRatio = .fill              // cover the view; may crop
```

| Case | Behavior |
|---|---|
| ``AspectRatio/default`` | Preserve the source aspect, fit into the smaller dimension |
| ``AspectRatio/ratio(_:_:)`` | Force a display aspect, **stretching** the source to it, then fit |
| ``AspectRatio/fill`` | Preserve the source aspect, fit the larger dimension, crop the overflow |

The mode is a `Player` property: it survives native-handle swaps, a
stopped drawable-hosted restart, and live drawable-size changes such as
rotation or split-screen. Set it once and it sticks.

## When to use PiPVideoView instead

For Picture-in-Picture, use ``PiPVideoView`` in place of ``VideoView``;
the two must not share a player. See <doc:PictureInPicture> for the setup
and for what macOS does and does not support.

## Taking a snapshot

Write the current video frame to disk as PNG:

```swift
try player.takeSnapshot(
    to: "/tmp/frame.png",
    width: 1920,        // pass 0 to derive from aspect ratio
    height: 0
)
```

The file is always PNG regardless of the path extension. Passing `0` for
both dimensions writes the frame at its native resolution. The call
throws ``VLCError/operationFailed(_:)`` when no frame is available — for
audio-only media, for instance — or when the file cannot be written.

## Overlays

Text, image, and colour overlays are added through scoped accessors on
the player. See <doc:VideoOverlays> for marquee, logo, video adjustments,
and the 360/VR viewpoint.

## Topics

### Views
- ``VideoView``
- ``PiPVideoView``

### Aspect
- ``AspectRatio``
- ``Player/aspectRatio``

### Video output state
- ``Player/videoSize``
- ``Player/hasVideoOutput``
- ``Player/activeVideoOutputs``

### Snapshot and recording
- ``Player/takeSnapshot(to:width:height:)``
- ``Player/startRecording(to:)``
- ``Player/stopRecording()``
