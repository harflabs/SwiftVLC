# Playback reliability: frozen video, A/V offset and audio-only playback

Production reports on beta.14 (macOS, `PiPVideoView`, IPTV/HLS/progressive and
local media): video sometimes freezes while audio continues, after pause and
resume or spontaneously, until a seek or another pause/resume.

None of this was visible to the test suite: 2,457 tests passed while every
defect below was live, because libVLC counts pictures *submitted* to the
display, not pictures shown. The evidence here comes from
`scripts/av-sync-harness`, which samples the frame actually on screen
(`AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer`, barcode-decoded) at
~250 Hz against the audio clock. Each native cause was confirmed with
single-file counterfactual engines against a no-op control build.

## Causes and fixes

**Resume after a timestamp discontinuity (patch 0055).** `vlc_clock_main_ChangePause`
shifted only the newest clock context by the pause length. Pictures still
queued from the previous timeline (TS PCR resets, HLS discontinuities, live
IPTV) converted late by the whole pause, were dropped as too late, and froze the
picture for as long as that video lasted (bounded by the caching window).
Backport of upstream !10644 (`89d58ef097`, `65e4977528`) and `b59b1c3753`;
upstream issue #30180 has the same symptoms.

| Pause 3 s just before each TS discontinuity | Resumes | First new frame | Frames lost |
|---|---|---|---|
| control engine | 15 | 13 frozen 230–910 ms | up to 25 |
| 0055 | 15 | 56–104 ms | 0 |

`TimestampJumpResumePlaybackTests` reproduces this headlessly through vmem and
is required in the rebuilt-engine CI job: the published beta.14 engine drops
the last 12 frames before each jump, with and without audio; 0055 drops none.

**A renderer queue holding a future-dated picture (patch 0056).**
AVSampleBufferVideoRenderer presents in timestamp order. A picture dated after
the next one, queued after a clock remap, holds every later picture until its
date while audio continues. The readiness gate then rejected each picture as
"not ready", hiding the freeze from libVLC's counters (once in 146 HLS
discontinuity pauses: 16 s frozen). `samplebufferdisplay` now flushes a queue
that would present out of order, or that accepted nothing for 300 ms.

- Across 98 pauses around HLS discontinuities with 0055–0056: no freeze after
  any resume, the first new frame after resume in 51–265 ms in 97 of them, and
  no hold over 150 ms during playback except at the discontinuity boundaries
  themselves (154–271 ms on 4 crossings; see 0063). The
  flush fired 12 times, each on a picture queued 0.52–0.75 s ahead, the class
  of mis-dating behind the original freeze. The remaining resume, paused three
  frames after a discontinuity while VLC rebuilt the decoder, took 0.77 s;
  pausing five frames after each of 14 discontinuities gave 55–107 ms on both
  the control and the patched engine, so it is not attributable to them.
- Six far-future samples injected directly into VLC's renderer (bypassing VLC,
  so only the no-progress path can see them) froze every earlier build for the
  full 8 s; with 0056 the picture recovers after 0.40–0.44 s.

**Video output abandoned before a drawable existed (patch 0057 + `Player`).**
When playback starts before any view can host video, libVLC fails to open a
display, unloads every video decoder and plays audio only, with no error;
attaching the view later never helped (4/4 runs with the view attached
0.3–1.5 s after `play()`). Two parts fix it: `Player` re-selects the video
track on the first playback-time update after playback starts or the drawable
changes, if a track is selected and no output has started; and 0057 stops
libVLC reusing the cached vout whose window was created for the old (absent)
drawable. `AbandonedVideoOutputPlaybackTests` reproduces the audio-only state
with real libVLC and requires the output to start within 3 s of attaching the
view (it fails on beta.14 even with the Swift change alone).

**Closing macOS PiP blanked the picture.** Closing PiP always re-selected the
video track, a workaround for the OpenGL display's context. Under the default
`samplebufferdisplay` that froze the picture until the next keyframe, and
showed nothing while paused until resume; it is now limited to the OpenGL
displays. On the same engine, three PiP closes while playing went from
0.92–1.03 s stalls to none, and after a close while paused the frame stays
on screen (before: no picture 95% of the time) and resume shows a new frame
in 117–133 ms instead of 762–844 ms.

**Tracks and subtitles.** Selection setters use libVLC's ordered, sticky
`select_tracks_by_ids` (a fast select-then-off no longer leaves the track on);
`Track.isIDStable` reports HLS/DASH ids that change on every seek and
selection, and a stale one resolves to the current matching track;
`addExternalTrack(select: true)` selects the file once it loads and does not
load a second copy; requested audio and subtitle delays are re-applied to
every new input instead of silently resetting to zero. Each is covered by
real-libVLC tests in `PlayerTrackSelectionTests` against the multitrack
fixtures in `Tests/SwiftVLCTests/Fixtures/tracks`.

**HLS `EXT-X-DISCONTINUITY` (patch 0063).** At a discontinuity the adaptive
demuxer resets the PCR, which flushes the decoders. It did so as soon as its own
queue reached the discontinuity, while the decoders still held up to the caching
delay of the previous timeline, so the last ~1.1 s before every discontinuity was
never displayed. It also mapped the new sequence's timestamps through the
previous sequence's synchronization reference, so after the first discontinuity
the player time stayed clamped to the duration or near zero for the rest of
playback. The demuxer now drains the output before the reset (non-blocking,
`ES_OUT_DRAIN` then `ES_OUT_IS_EMPTY`) and anchors each new sequence at the
playlist time where it begins. On a 20 s-per-sequence fixture: frames never
shown per discontinuity 34–35 → 0–2, picture hold at the boundary 620–853 ms →
289–350 ms, and the player time follows the playlist (21.1 s after the 20 s
boundary instead of 321 s or 1.1 s). Pauses around discontinuities stay clean.
`HLSDiscontinuityPlaybackTests` (vmem, required in the native CI job) fails on
the previous engine (frames 90–119 and 210–239 dropped, wrong time) and passes.

**Rate changes and audio device switches (patch 0064).** CoreAudio reported
its timing to the clock once a second. A rate change becomes audible only once
the audio already rendered at the previous rate has played (the caching delay,
1–1.5 s here); the audio-master clock then kept extrapolating the previous rate
until the next report and stepped back, stalling video 0.3–1 s on every
slow-down. Timing is now reported every 100 ms. Over 12 rate changes (1.5×, 2×,
0.5× and back): no stall over 150 ms (before: 4), longest frame hold 38–102 ms,
and the new rate settles about 1.2 s after the call (before: 1.5–2 s). The A/V
offset right after an audio output device switch drops from +226–293 ms to
12–48 ms. Five minutes of TS playback at 1× show the same picture holds with
and without it (none over 60 ms outside the timestamp discontinuity, ~190 ms
at it on both). `RateChangePlaybackTests` (real audio output, local) fails before and
passes. Bounding CoreAudio's output queue to apply rates sooner was tried and
rejected: VLC paces local inputs by decoder queue length, so blocking the audio
decoder starved video at every GOP boundary.

**Upstream backports (0058–0062).** avcC/hvcC without parameter sets (no video
on avc3/hev1 streams), SRT arrows surrounded by tabs, SPU cache invalidation,
deselecting finished MP4 tracks, and audio output delay correctness.

## Regression checks

With 0055–0056 (the same harness): plain pause/resume of 0.3–10 s on local
and HLS VOD, window miniaturize and occlusion, pause while hidden, PiP view
re-attach and paused seek/resume showed no stalls and first frames within
13–173 ms, matching beta.14. The full Swift suite passes against the rebuilt
engine and against the published beta.14 engine, and all 64 native patches
replay on the pinned VLC source with mutation-checked source contracts.

## Known limits (not fixed here)

- Seeking HLS across `EXT-X-DISCONTINUITY` sequences: the adaptive demuxer
  refuses seeks while a discontinuity drains through its queue (most of each
  sequence when it is far ahead of playback), and a seek into a sequence that
  has not played yet has no timestamp reference and lands imprecisely. Same on
  the previous engine; not changed by 0063.
- The picture holds about 0.3 s at each HLS discontinuity while the demuxer
  rebuffers after its PCR reset.
- A rate change still takes effect only after the caching delay of audio
  already rendered at the previous rate (about 1.2 s here). `--aout=avsamplebuffer`
  keeps the previous one-second timing reports.
- Bluetooth/AirPlay output latency and device switches to them are unmeasured.
- Measured on macOS only (Apple silicon, 60 Hz display). iOS/tvOS devices,
  display/system sleep and 120 Hz displays are untested.
