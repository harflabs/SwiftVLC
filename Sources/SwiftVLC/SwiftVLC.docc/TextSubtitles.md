# Text subtitles

Render text subtitles in your own interface instead of libvlc.

## Enable subtitle capture

Call ``Player/textSubtitleStream()`` before playback starts. If you do not call
it, libVLC renders subtitles normally.

```swift
let player = Player()
let subtitleSnapshots = try player.textSubtitleStream()

let presentation = Task { @MainActor in
    for await snapshot in subtitleSnapshots {
        if snapshot.regions.isEmpty {
            subtitleOverlay.hide()
        } else {
            // Convenient when the overlay does not implement region placement.
            subtitleOverlay.show(snapshot.text)
        }
    }
}

try player.play(Media(url: movieURL))
```

Calling the method after playback starts throws ``VLCError/invalidState(_:)``.
It throws ``VLCError/operationFailed(_:)`` when the linked libVLC build does not
support subtitle capture. Capture remains enabled for the player's lifetime.

## Select a track

Select embedded subtitle tracks as you normally would. Listen for track
changes, refresh the tracks, and choose one:

```swift
let events = player.events
let subtitleSnapshots = try player.textSubtitleStream()
try player.play(Media(url: movieURL))

for await event in events {
    guard case .tracksChanged = event else { continue }
    player.refreshTracks()

    if let english = player.subtitleTracks.first(where: { $0.language == "eng" }) {
        player.selectedSubtitleTrack = english
        break
    }
}
```

Each ``TextSubtitleSnapshot`` contains the currently displayed regions in
presentation order. Each ``TextSubtitleRegion`` has text and a
``TextSubtitlePlacement``. The snapshot's `text` property joins the regions
with newlines. An empty snapshot means the overlay should be cleared.

## Position subtitles

Use ``TextSubtitlePlacement/automatic`` for your app's normal subtitle layout.
WebVTT regions use ``TextSubtitlePlacement/webVTT(_:)`` and include their cue
placement as a ``WebVTTPlacement``.

WebVTT positions and size limits use normalized video coordinates. Positions
may fall outside `0.0 ... 1.0`. Anchors identify which point of the cue box sits
at that position. The value also includes text alignment and writing direction.

A WebVTT cue without placement settings is bottom-centered with no size limit.
Render multiple regions in array order so each keeps its own placement.

```swift
for await snapshot in subtitleSnapshots {
    subtitleOverlay.removeAllRegions()

    for region in snapshot.regions {
        switch region.placement {
        case .automatic:
            subtitleOverlay.addAutomaticallyPlacedText(region.text)
        case .webVTT(let placement):
            subtitleOverlay.addWebVTTText(region.text, placement: placement)
        }
    }
}
```

## Supported formats

The stream supports decoded text formats such as SubRip, WebVTT, TTML, and
`mov_text`. It does not convert image subtitles such as PGS or VobSub to text.
ASS/SSA subtitles rendered as images by libass are not included either.

## Stream behavior

Each call to ``Player/textSubtitleStream()`` creates an independent stream and
starts with the latest snapshot. SwiftVLC skips duplicate snapshots and keeps
only the newest pending value for a slow consumer.

SwiftVLC copies each snapshot into `Sendable` values before delivering it. The
`for await` loop runs on the task's executor, not on libVLC's callback thread.
Stopping or replacing media, reaching the end, or encountering an error clears
the snapshot. Replacing the native player keeps the stream open.

## Topics

### Custom presentation

- ``Player/textSubtitleStream()``
- ``TextSubtitleSnapshot``
- ``TextSubtitleRegion``
- ``TextSubtitlePlacement``
- ``WebVTTPlacement``
