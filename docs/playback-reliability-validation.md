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

## Final review before 1.1.0 (patches 0065–0071)

A second pass ran real libVLC through the flows an app uses every day and
compared what the player reports with what actually happened. Each item below
was reproduced on the beta.15 engine first, then fixed, and has a real-libVLC
test that fails on that engine.

**A non-fatal failure no longer breaks the session or its end (patch 0065).**
libVLC recorded the first failure of any stream and from then on reported
`Error` as its state, although the input kept playing. Starting playback before
a view existed, a selected track without a decoder, or an external subtitle
file that was missing was enough. `resume()` and `togglePlayPause()` then did
nothing after a pause, and the clean end of the file arrived as
`encounteredError` with `didReachEnd == false`. A video file played with no
view at all ran to its last sample and ended as `.failure(.renderer)`. Now a
recorded failure is an error only once it ends the input, an input that
presented anything ends naturally, and one that presented nothing fails. Data
in which no demuxer finds a stream used to "play" and end as a natural end at
time zero; it ends as `.failure(.demux)`.

**The time reported while paused (patch 0066).** Every redisplay of a paused
picture republished that picture's timestamp as the playback time. With a
picture older than the audio position (the video track of
`early-video-end.mp4` ends four seconds before its audio) pausing at 5.1 s made
libVLC report 1.8 s, which relative seeks then started from. With a real audio
output, a paused seek on audio-only playback (or on video without an output)
published no point until playback resumed: the first seek "settled" at the
position before the seek and the published time snapped back to it, and every
later paused seek timed out behind it. `--aout=dummy`, which the headless
suite uses, hid this. Paused getters now return the pending seek target, and
those seeks settle at once.

**Seeks without a video output (Swift).** A selected video track whose output
libVLC abandoned never submits a picture, so every seek waited two seconds for
one with the published time frozen. Output evidence is required only while a
local video output is running: such seeks settle in 70–270 ms.

**The extended vmem output (patch 0067).** Setting an aspect ratio on a player
rendered through a directly constructed `PiPController` crashed the process
(the core called a null picture-reset operation), and a sample aspect ratio
that no whole number of square pixels can express exactly (1920x816 at
817:816) was rejected on every attempt: audio with a black picture, no error
(issue #250).

**Rate across a resolution switch (patch 0069).** A format change restarts
the display in place and reset it to rate 1. On a video-only stream that
changes resolution after two seconds, played at 2x, the pictures after the
switch ran at 1.00x; they run at 2.00x.

**HLS with a selected subtitle rendition (patch 0070).** Patch 0063 cleared
every stream's synchronization reference at a discontinuity. A WebVTT stream
cannot anchor the new sequence itself; it waited for the video stream's
reference while holding back the demux deadline the video stream needed to
publish one. Audio and video stopped for good just before the discontinuity
with the state still playing. Muxed HLS without subtitles was unaffected,
which is what the 0063 fixture covered.

**Memory over long playback (patch 0071).** The video output thread has no
autorelease pool, and `AVSampleBufferVideoRenderer` autoreleases an object on
every readiness query, enqueue and flush: about 160 bytes per picture, tens of
megabytes per hour, until the output closes.

**Patch 0068** drops a paused frame demand that can be processed after its
resume and would make the next pause demux at full speed. It was found by
reading the control ordering; 144 pause, seek and immediate-resume cycles did
not reproduce it.

Scrubbing, repeated skips and long media needed no change: a 60 Hz drag over
three seconds followed by a precise seek shows the target frame within one
frame of the request, fifteen 2-second skips in 0.7 s land exactly 30 s on,
and precise seeks on a 12-hour file land on the requested frame at every
position tried, including the last half second.

## Regression checks

With 0055–0056 (the same harness): plain pause/resume of 0.3–10 s on local
and HLS VOD, window miniaturize and occlusion, pause while hidden, PiP view
re-attach and paused seek/resume showed no stalls and first frames within
13–173 ms, matching beta.14. The full Swift suite passes against the rebuilt
engine and against the published beta.14 engine, and all 64 native patches
replay on the pinned VLC source with mutation-checked source contracts.

## Known limits (not fixed here)

- HLS with a separate audio rendition (`EXT-X-MEDIA:TYPE=AUDIO`) and
  `EXT-X-DISCONTINUITY`: the streams reach the discontinuity in different
  demux rounds, so the drain and reset of 0063 never run. Playback stalls at
  the discontinuity when timestamps jump, or skips the rest when they restart.
  Same on every earlier engine; 0063 and 0070 cover muxed streams.
- A connection the server closes mid-stream without an error ends as a
  natural end, as does a truncated file at its last readable sample. Compare
  the terminal outcome's final time with the duration.
- The interval of the audio timing reports of 0064 applies to CoreAudio
  (`auhal`, `audiounit_ios`). `avsamplebuffer`, the default audio output on
  iOS, tvOS and visionOS, still reports once a second, so the clock step after
  a rate change described above is unchanged there.

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
