# Video overlays

Text marquees, image logos, color adjustments, and 360/VR viewpoints.

## Ownership-aware overlays

``Marquee``, ``Logo``, and ``VideoAdjustments`` are `~Copyable` and
`~Escapable`. They hold a pointer into the player and are scoped to the
player's lifetime, which means the compiler rejects any attempt to
store them in a property, return them from a function, or capture them
in a `Task`.

Use them either one-off through a property, or inside a `with*` scope
for batched mutations:

```swift
player.marquee.isEnabled = true
player.marquee.setText("LIVE")

player.withLogo { logo in
    logo.isEnabled = true
    logo.setFile("/tmp/watermark.png")
    logo.opacity = 200
}
```

## Marquee (text overlay)

``Marquee`` displays a text string on top of the video. It supports
strftime-style placeholders refreshed at the interval configured by
``Marquee/refresh``:

```swift
player.withMarquee { m in
    m.isEnabled = true
    m.setText("%H:%M:%S")
    m.refresh = 1000              // refresh every second
    m.fontSize = 24
    m.color = 0xFFFFFF
    m.screenPosition = .bottomLeft
}
```

Anchoring uses ``OverlayPosition``, an `OptionSet` whose flags compose
into corners (`.topLeft`, `.bottomRight`, …) or an empty set for the
center. The raw ``Marquee/position`` `Int` bitmask remains available for
libVLC-flavored code.

## Logo (image overlay)

``Logo`` layers a PNG (or a sequence of PNGs for animation) on top of
the video:

```swift
player.withLogo { logo in
    logo.isEnabled = true
    logo.setFile("/tmp/logo.png")
    logo.opacity = 200            // 0–255
    logo.screenPosition = .topRight
}
```

For an animated sequence, pass `"file,delay,transparency;…"` to
``Logo/setFile(_:)``.

## Video adjustments

Tweak contrast, brightness, hue, saturation, and gamma in real time:

```swift
player.withAdjustments { adj in
    adj.isEnabled = true
    adj.contrast = 1.1
    adj.brightness = 1.05
    adj.saturation = 1.2
}
```

## 360 / VR viewpoint

For equirectangular or cubemap content, animate the viewpoint with
``Player/updateViewpoint(_:absolute:)``:

```swift
try player.updateViewpoint(
    Viewpoint(yaw: 90, pitch: 0, fieldOfView: 80)
)
```

Pass `absolute: false` to nudge the viewpoint relative to the current
orientation, which is useful for gyroscope-driven look-around.

## Topics

### Overlays
- ``Marquee``
- ``Logo``
- ``VideoAdjustments``

### Scoped access
- ``Player/withMarquee(_:)``
- ``Player/withLogo(_:)``
- ``Player/withAdjustments(_:)``

### 360/VR
- ``Viewpoint``
- ``Player/updateViewpoint(_:absolute:)``
