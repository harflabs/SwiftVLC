# Seek frame oracle

Original synthetic media generated for SwiftVLC; no third-party content.
320×180, 30 fps, 60 s, H.264 with B-frames and 250-frame GOPs, AAC audio.
The top 64 pixels encode the zero-based frame number as 16 binary bars.
This gives an independent content-time oracle: frame number / 30 seconds.
HLS is a stream-copy of the MP4; MPEG-TS video PTS starts at 1.466666 seconds.

Regenerate: `python3 scripts/ci/make-seek-frame-fixture.py Tests/SwiftVLCTests/Fixtures/seek-oracle`
Verify pixels with FFmpeg: add `--verify-only`. Encoder versions can change bytes.
The checked-in assets are bound by SHA256SUMS. VLC timestamps are checked against
both the decoded barcode and the independently known container time origin.

The MKV remux adds a selected SRT cue every second. Its first video PTS is
0.021333 seconds (AAC mux offset); the pixel barcode still gives content time.
It reproduces subtitle-driven input advancement after a paused seek.

`timestamp-jump.ts` re-encodes frames 0–359 of the MP4 as three 4-second
MPEG-TS runs whose timestamps jump by +3000 seconds at frame 120 and back at
frame 240, concatenated like a broadcast PCR reset. It reproduces frames
dropped after resuming a pause taken just before a jump (patch 0055).
`hls-discontinuity/` lists the same three runs as HLS segments separated by
`EXT-X-DISCONTINUITY`: the frames before each discontinuity must be displayed
and the player time must follow the playlist across it (patch 0063).

The second MP4, `open-gop.mp4`, is a 12-second, 320×192 H.264 open-GOP
sequence with two-second recovery points, three B-frames, AAC, the same barcode,
and moving color detail below it. Its dimensions are multiples of 16 to avoid
conflating hardware output cropping with seek recovery. The five `.argb` files
are independently decoded FFmpeg reference frames at 2, 3, 6, 7, and 9 seconds.
Whole-image comparison catches corruption that leaves the barcode intact.
Hardware tests explicitly verify selection of VideoToolbox and reject a software
fallback; software decoding of the identical fixture is the control.
