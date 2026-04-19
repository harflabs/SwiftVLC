# Audio features

Tune volume, output routing, channel mixing, and equalization.

## Volume, mute, delay

```swift
player.volume = 0.8            // 0.0 silent, 1.0 is 100%, up to 1.25
player.isMuted = false
player.audioDelay = .milliseconds(30)    // positive = audio plays later
```

Volume is normalized, so `0.0 ... 1.0` covers the useful range; values
above `1.0` amplify beyond normal (capped around 1.25 / 125%).

## Output modules and devices

List available output modules (CoreAudio, auhal, etc.) for the running
instance:

```swift
for module in VLCInstance.shared.audioOutputs() {
    print(module.name, module.outputDescription)
}
try player.setAudioOutput("auhal")   // macOS example
```

Then pick a device within that module:

```swift
for device in player.audioDevices() {
    print(device.deviceId, device.deviceDescription)
}
try player.setAudioDevice("external-speakers-uid")
```

Observe ``PlayerEvent/audioDeviceChanged(_:)`` if you need to react to
system-initiated device changes (e.g. headphones connecting).

## Equalizer

``Equalizer`` is a 10-band parametric EQ with a preamp and preset
support. Build one, tune it, and attach it to a player:

```swift
let eq = Equalizer()
eq.preamp = 4.0                              // dB; clamped to -20...+20
try eq.setAmplification(5.0, forBand: 0)     // bass lift
player.equalizer = eq
```

Use a built-in preset by index:

```swift
let rock = Equalizer(preset: Equalizer.presetNames.firstIndex(of: "Rock") ?? 0)
player.equalizer = rock
```

Pass `nil` to disable: `player.equalizer = nil`.

## Channel layout

Two independent properties shape the output signal:

- ``Player/stereoMode`` picks a stereo transformation (standard,
  reversed, mono, or Dolby Surround).
- ``Player/mixMode`` selects the channel count of the final mix,
  including stereo, 4.0, 5.1, 7.1, and binaural rendering for
  headphones.

```swift
player.stereoMode = .mono        // collapse to mono
player.mixMode = .binaural       // spatialize for headphones
```

## Role hints

Tell the system what kind of audio you're playing so it can route and
duck appropriately:

```swift
player.role = .music         // long-form listening
player.role = .communication // voice chat; enables VoIP-style processing
```

See ``PlayerRole`` for the full set.

## Topics

### Volume
- ``Player/volume``
- ``Player/isMuted``
- ``Player/audioDelay``

### Output routing
- ``Player/setAudioOutput(_:)``
- ``Player/audioDevices()``
- ``Player/setAudioDevice(_:)``
- ``Player/currentAudioDevice``
- ``AudioOutput``
- ``AudioDevice``

### Equalization
- ``Equalizer``
- ``Player/equalizer``

### Channel layout and role
- ``Player/stereoMode``
- ``Player/mixMode``
- ``Player/role``
- ``StereoMode``
- ``MixMode``
- ``PlayerRole``
