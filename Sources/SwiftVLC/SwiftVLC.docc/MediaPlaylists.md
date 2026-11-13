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

When the source URL is itself a playlist container — `.pls` or classic
`.m3u` — add that ``Media`` to a ``MediaList`` and play it through
``MediaListPlayer``, which lets libVLC expand the entries. Passing such a
URL straight to ``Player/play(url:)`` does not work. HLS `.m3u8` is the
exception: it is a streaming manifest and ``Player`` plays it directly.

``MediaList`` is `Sendable` and thread-safe; every mutation takes the
underlying libVLC lock. For batch reads that need a consistent snapshot,
hold the lock across the whole scope with ``MediaList/withLocked(_:)``:

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

A `Player` has one live list-player owner. Assigning the same player to a
second `MediaListPlayer` transfers ownership without stopping its current
playback. Setting ``MediaListPlayer/mediaList`` to `nil` also leaves that
playback running; set ``MediaListPlayer/mediaPlayer`` to `nil` or call
``MediaListPlayer/stop()`` when the player itself should stop.

While a list player is attached, the ``Player`` does not synthesize
``PlayerEvent/endReached-enum.case``: list advancement stops the native
handle between items through calls the player cannot tell apart from a
natural end. Track item boundaries through the list player instead.

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

### Attaching
- ``MediaListPlayer/mediaPlayer``
- ``MediaListPlayer/mediaList``
- ``MediaListPlayer/playbackMode``

### Control
- ``MediaListPlayer/play()``
- ``MediaListPlayer/play(at:)``
- ``MediaListPlayer/play(_:)``
- ``MediaListPlayer/next()``
- ``MediaListPlayer/previous()``
- ``MediaListPlayer/togglePause()``
- ``MediaListPlayer/stop()``
