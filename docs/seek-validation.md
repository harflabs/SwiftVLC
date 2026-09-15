# Seek output contract and validation

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
