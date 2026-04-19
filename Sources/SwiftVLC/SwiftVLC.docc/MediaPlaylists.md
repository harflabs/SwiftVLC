# Media playlists

Chain multiple ``Media`` items with ``MediaList``, and advance through
them automatically using ``MediaListPlayer``.

## Building a list

```swift
let list = MediaList()
try list.append(Media(url: url1))
try list.append(Media(url: url2))
try list.insert(Media(url: url3), at: 1)
```

``MediaList`` is `Sendable` and thread-safe. Every mutation acquires
the underlying libVLC lock automatically.

For batch reads that must see a consistent snapshot, hold the lock
across the whole scope with ``MediaList/withLocked(_:)``:

```swift
let mrls = list.withLocked { view in
    (0..<view.count).compactMap { view.media(at: $0)?.mrl }
}
```

The view passed to the closure is `~Copyable` and `~Escapable`, so the
compiler rejects any attempt to store or return it.

## Playing the list

Attach a ``MediaListPlayer`` to an existing ``Player``:

```swift
let listPlayer = MediaListPlayer()
listPlayer.mediaPlayer = player
listPlayer.mediaList = list
listPlayer.playbackMode = .loop
listPlayer.play()
```

Control is per-item:

```swift
try listPlayer.next()
try listPlayer.previous()
try listPlayer.play(at: 3)
listPlayer.togglePause()
listPlayer.stop()
```

## Playback modes

| Mode | Behavior |
|---|---|
| ``PlaybackMode/default`` | Play through once, then stop |
| ``PlaybackMode/loop`` | Repeat the whole list |
| ``PlaybackMode/repeat`` | Repeat the current item |

## Topics

### Types
- ``MediaList``
- ``MediaListPlayer``
- ``PlaybackMode``

### Mutating the list
- ``MediaList/append(_:)``
- ``MediaList/insert(_:at:)``
- ``MediaList/remove(at:)``

### Scoped reads
- ``MediaList/withLocked(_:)``
- ``MediaList/LockedView``

### Control
- ``MediaListPlayer/play()``
- ``MediaListPlayer/play(at:)``
- ``MediaListPlayer/next()``
- ``MediaListPlayer/previous()``
- ``MediaListPlayer/stop()``
