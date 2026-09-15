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
