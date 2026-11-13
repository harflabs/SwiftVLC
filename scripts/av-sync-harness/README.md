# A/V sync and video-freeze harness (macOS)

Measures what is actually on screen while SwiftVLC plays, instead of trusting
libVLC's own counters (which count pictures *submitted*, not displayed). It
produced the evidence for the playback patches in `scripts/patches/`, each of
which states its own findings in its header.

## What it measures
`avh` plays a fixture whose frames carry a 20-bit frame-index barcode through the
production path (`Player` with `PiPVideoView` or `VideoView`, VLC
`samplebufferdisplay`, `auhal`). A sampler thread at ~250 Hz records:

- the frame on screen, from `AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer`
  on VLC's own layer, barcode-decoded;
- VLC's audio-master clock (`libvlc_media_player_get_time`);
- every 500 ms, VLC statistics and renderer state; plus libVLC events and the
  full debug log (`--log`), and optionally the JSON tracer (`--tracer FILE`).

`analyze.py` reports the A/V offset (on-screen frame PTS − audio clock), stalls
(frame unchanged > 150 ms while Playing and the clock advances), time to the
first new frame after each resume/show/rate mark, and frames shown vs expected.

## Run
```sh
./make_fixtures.sh ~/avfix 1800            # av30.mp4, hls-vod/, av30.ts (needs ffmpeg)
python3 serve.py ~/avfix 8765 &            # Range-capable HTTP for progressive/HLS cases
AVH=$(./prepare.sh /tmp/avh [engine.xcframework])   # default engine: Vendor/libvlc.xcframework
./run.sh "$AVH" /tmp/runs pauses ~/avfix/av30.mp4 pauses --pauses 0.3,1,3,10 --cycles 2 --after 4
```

Scenarios (`--scenario`): `pauses`, `run`, `pause_at_frames` (pause just before
given frames, e.g. timestamp discontinuities), `pseek_resume`, `resume_seek`,
`miniaturize`, `orderout`, `occlude`, `pause_hidden`, `hidden_pause`,
`reattach`, `pip` (open/close macOS PiP while playing and paused), `seeks`
(absolute seeks to each `--pauses` value), `audiodev`,
`rate`, and `inject` (enqueue far-future samples into VLC's renderer).
`--attach-delay S` starts playback S seconds before the view exists.
Discontinuity fixtures are cut from `av30.mp4` with
`-ss k*20 -t 20 -c copy -output_ts_offset (100|3100)` and concatenated (TS), or
listed with `EXT-X-DISCONTINUITY` (HLS).

## Counterfactual engines
`build_variant.py VLC_TREE HEADERS.xcframework OUT.xcframework PATCH...` rebuilds
only the files a patch touches from a `build-libvlc.sh --macos-only` build tree
and relinks a macOS-arm64 engine in about 20 s, leaving the tree untouched. Use
a no-op patch (a comment change) as the control for every A/B.
