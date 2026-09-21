# Seek output contract and validation

## Resume and mixed seek commands (beta.14)

Tilfaz's all-platform report exposed additional timeline and decoder problems:

- VLC 4's `:start-time` is a clipping option, not a full-media resume seek.
  [`ControlSetTime` and `input_GetItemDuration`](https://github.com/videolan/vlc/blob/c833c4be000b426d73ff4324bec574065f00e3df/src/input/input.c)
  respectively add the start offset to seeks and subtract it from duration.
  A 60-second fixture with `:start-time=20` reports 40 seconds; seeking to 5
  displays barcode frame 750 (original-media time 25 seconds). Loading without
  the option, seeking to 20, then back to 5 displays frame 150 and retains the
  60-second duration. Applications must use the latter for saved progress.
- A strict relative request only combined with a queued strict relative
  request. It discarded queued absolute/fractional scrub intent and instead
  used the active seek's optimistic clock. Under delayed HTTP, 36 seconds
  active → 20 seconds queued → back 15 must land at 5. The beta.13 negative
  control failed in both paused and playing states. Composition now retains
  the queued base and offsets through observation timeout, resolves fractional
  bases and clamps at dispatch, and uses the latest precision policy.

- Subtitle flushes leave a nonzero `frames_countdown` to permit subtitle output
  while paused. The empty decoder FIFO path incorrectly treated this as a
  video frame-step demand. A selected sparse subtitle track repeatedly made
  the paused input demux ahead, leaving the input wakeup in the future after
  resume. A five-second pause then caused late-frame drops and a frozen legacy
  time event stream. The same MKV with subtitles disabled resumed correctly;
  an original numbered-frame fixture with SRT reproduced the failure. Patch
  0051 limits frame-step input demand to video decoders. Replacing only this
  decoder object corrected both video and clock in the synthetic fixture and
  the public Tilfaz demo movie, with audio enabled and disabled. Full rebuilt
  engine and device qualification are still required before release.

- VideoToolbox H.264 open-GOP recovery retained references across seeks to
  non-IDR recovery pictures. It also submitted leading B pictures whose
  dependencies preceded the new recovery point. Resetting the first recovery
  sample and discarding those leading pictures are both necessary (patch 0052).
  Reset alone removed some corruption but still caused decoder errors and wrong
  landings. Together they matched independently decoded frames in the public
  demo and removed its gray first-seek picture in the iOS simulator. The original
  decoder fails the synthetic whole-image comparison at 3 seconds with mean
  channel error 21.20; the corrected decoder produces error 0.00. This follows
  [Apple's documented reset attachment](https://developer.apple.com/documentation/coremedia/kcmsamplebufferattachmentkey_resetdecoderbeforedecoding)
  and [Chromium's H.264 recovery implementation](https://chromium.googlesource.com/chromium/src/media/+/d42064588059042463282f90df67411c8b88fb24).
  `VideoToolboxSeekPlaybackTests` verifies both decoder selection and complete
  reference pixels, and then checks that playback resumes with matching time.

- Paused buffering and output startup used different wall-clock origins.
  Buffering anchored its PCR to the pause time, but decoder startup and the
  monotonic fallback used current wall time; a clock reset also discarded the
  pause origin needed at resume. The open-GOP MP4 exposed frozen output or
  accelerated playback after repeated paused seeks, including with software
  decoding. Patch 0053 preserves the pause origin across resets and uses it for
  both startup and fallback references. Updating startup alone regressed the MKV
  controls because the first paused picture can establish the fallback before
  startup. Keeping all three paths consistent passes the combined MP4 and MKV
  regression cases. A paused seek's first picture also waits for buffering to
  establish its output clock before submission. Tests compare output pixels with the clock after resuming,
  including repeated pause/seek/resume cycles and different pause durations.

- VideoToolbox's picture pool can fill while output is paused. The decoder
  thread then waits for pictures to be released, but that same thread normally
  applies the output's resume control. The failed audio-disabled regression
  showed zero pending decodes and 16 allocated fields at its 16-field limit;
  video stayed at 6 seconds for another 20 seconds while the public clock ran
  to the end. Patch 0054 resumes an already-paused video output under the decoder
  FIFO lock in the control caller. This frees pictures so the decoder thread can
  return and acknowledge the new pause date. Its existing acknowledgement path
  remains intact. Software decoding and audio-on cases are retained as controls.

`ResumeTimelinePlaybackTests` checks independently encoded pixels for resume
and delayed mixed commands. `PlayerMixedSeekTests` covers absolute, strict
fractional and raw fractional bases, expired/live requests, changing duration,
repeated offsets and both precision policies. Tilfaz additionally stops
overwriting engine observations with requested times and uses relative engine
requests for skip buttons.

## The defects and their causal evidence

1. **Lost final intent under network delay.** With a 3.5-second delay on HTTP
   range responses, seeking fast to 36 seconds and then precisely to 12 seconds
   expired both 2-second observation windows. The old scheduler removed the
   queued 12-second command before dispatch. The decoder eventually displayed
   the earlier keyframe at 33.333 seconds. A no-delay control sent both commands;
   extending the windows diagnostically also sent both. The fix separates the
   public observation deadline from the lifetime of the latest queued intent.
2. **Late output discarded after timeout.** Canceling monitor ownership at the
   active deadline prevented the eventual native landing from correcting the
   optimistic paused timeline. A deadline preserves pending native work;
   output can update observed time while the original result remains terminal
   `.timedOut`. Once seek-end and a subsequent clock prove the native episode
   completed, an expired video observation releases the navigation lease even
   if no frame arrives. Late output remains observable until another seek,
   frame request, or timeline replacement takes ownership.
3. **Paused adaptive decoder replacement.** HLS can replace its video decoder
   during a seek. The old decoder's flush allowance did not reach the replacement.
   Treating bootstrap as a next-frame request then hit the explicit frame-step
   guard before a video output existed. Direct libVLC reproduced the freeze,
   excluding Swift scheduling. Separate paused-seek bootstrap permits the first
   picture without entering frame-step result bookkeeping. EOF retires that
   demand; an independently observed stress failure caught this lifecycle edge.
4. **Clock updates mistaken for output.** An ordinary timer point after seek-end
   could produce `.settled` while no new frame was submitted. Native extension 12
   adds an opt-in callback at the successful output-submission boundary. Swift
   requires this callback for video selected at dispatch and checks precise absolute targets
   against its media-normalized timestamp. Out-of-bound output returns
   `.inaccurate` and publishes the observed time.
5. **Presentation-time mapping and preroll.** MP4 edit offsets were conditionally
   skipped for early decode timestamps. HLS could combine invalid timestamps into
   a zero origin, then anchor video to decoding rather than presentation time.
   Both shifted content relative to the requested timeline. The fixes preserve
   valid presentation origins and apply the display threshold to existing and
   replacement decoders. A seek beyond the final picture submits the last actual
   preroll picture at EOF; its observed timestamp remains subject to the bound.

The upstream base is VLC `c833c4be000b426d73ff4324bec574065f00e3df`, followed by
SwiftVLC's ordered patch manifest. Relevant upstream code is
[`FakeESOut.cpp`](https://github.com/videolan/vlc/blob/c833c4be000b426d73ff4324bec574065f00e3df/modules/demux/adaptive/plumbing/FakeESOut.cpp),
[`PlaylistManager.cpp`](https://github.com/videolan/vlc/blob/c833c4be000b426d73ff4324bec574065f00e3df/modules/demux/adaptive/PlaylistManager.cpp), and
[`mp4.c`](https://github.com/videolan/vlc/blob/c833c4be000b426d73ff4324bec574065f00e3df/modules/demux/mp4/mp4.c).
HLS timing semantics are described in [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216.html).
The implementation and executable source guards are patch 0050 and
`scripts/patches/validation/seek-video-output-source-check.py`.

## What establishes correctness

- **Independent content oracle:** synthetic video encodes each frame number in
  its pixels. At 30 fps, frame 705 means 23.5 seconds, independently of VLC's
  getter, timer, or Swift state. FFmpeg verifies the encoded barcodes; fixtures
  include hashes and a generation script.
- **At-settlement assertions:** a new submitted frame must already be present
  when the request resolves. Its barcode and media time must match; a later
  callback cannot conceal a false success. Paused state is checked again after
  a delay to catch a stale timer overwriting the result.
- **Transport and state coverage:** MP4, local HLS and HTTP HLS; audio on/off;
  paused and playing controls; repeated forward/backward targets; early pause;
  zero, fractional-frame targets, the last frame, and a seek away from EOF.
- **Deadline fault injection:** two 3.5-second HTTP response delays must produce
  terminal timeout observations while still dispatching the final intent and
  eventually displaying its pixels. Paused and playing cases both apply.
- **Missing-output liveness:** deterministic tests cover the deadline on either
  side of native seek completion, a queued successor, late output without a
  successor, and retirement at external-seek/frame-request boundaries. A clock
  may release an expired lease but cannot produce video `.settled`. Paused
  audio retains its post-end getter proof after timeout. The evidence mode is
  frozen at dispatch: later track selection cannot remove a clock-only seek's
  fallback or weaken a video seek's output requirement. Rejected or unproven
  successors preserve the prior late observation, including output arriving
  inside the unsuccessful setter call.
- **Adjacent behavior:** full Swift tests, strict-frame burst/EOF/ordering probes,
  native patch replay, ABI and symbol verification, and mutation-sensitive source
  checks. CI requires the output-oracle suite to execute against the rebuilt
  engine; only the published older engine may skip those exact tests.

Run against a rebuilt local XCFramework:

```sh
python3 scripts/ci/use-local-native.py
CI=true SWIFTVLC_NATIVE_SEEK_TESTS=1 swift test --no-parallel
python3 scripts/ci/make-seek-frame-fixture.py Tests/SwiftVLCTests/Fixtures/seek-oracle --verify-only
./scripts/validate-native-patch-series-source.sh
```

Restore the temporary Package.swift override before committing. The release
pipeline additionally requires two clean all-platform native builds with matching
bytes and provenance. A diagnostic archive with replaced objects is not release
provenance.

## Limits of the evidence

A successful output submission is not proof of physical display scanout.
Hardware decoding, actual Apple display surfaces, PiP and device lifecycle paths
need device qualification against the exact candidate. The synthetic regressions
prove the specified defects; the originally reported media and interaction must
also be replayed when available. VFR, discontinuities and unusual edit lists need
additional fixture coverage before claiming universal frame accuracy. Native
watchers still use sole-episode attribution rather than native seek request IDs;
ambiguous external overlapping controls remain fail-closed.

Timeout is intentionally observational: a latest accepted seek may execute after
its waiter has received `.timedOut`. A new seek or media/lifecycle replacement
supersedes that intent. Older published engines retain clock-only compatibility;
they do not acquire the extension-12 output guarantee through the Swift update.

### Review follow-up: subtitle demand ownership

Patch 0051 guards both setting and clearing the shared frame-step data request.
Only a video decoder owns that request; a subtitle FIFO becoming nonempty must
not cancel a video decoder's outstanding demand either. The source contract
checks and mutation-tests both guards.

This does not remove normal paused-seek buffering: `input.c:MainLoop` continues
calling the demux while `es_out_GetBuffering()` is true even in `PAUSE_S`.
The SPU flush countdown remains intact so subtitles consume the packets supplied
by that buffering. With no video output, `ModuleThread_NewSpuBuffer` already
returns NULL after failing to find a vout, so unbounded frame-step demux cannot
provide subtitle-only presentation. Adding such presentation requires a separate
output implementation; keeping the input clock advancing while paused cannot
supply it safely.

The symmetric guards pass all eight parameter cases in
`ResumeTimelinePlaybackTests` using a replacement core object. Full native
rebuild and Apple video-output qualification remain required for release.
