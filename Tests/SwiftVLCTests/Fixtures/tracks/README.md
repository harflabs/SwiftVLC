# Track-selection fixtures

Original synthetic media generated for SwiftVLC; no third-party content.
Every file carries a black 64x36, 5 fps H.264 picture: without a video output
libVLC's subtitle decoder stalls for seconds per cue waiting for one.

`multitrack.mkv` is 10 s with two mono AAC tracks (eng 440 Hz, ara 660 Hz) and
two SRT tracks (eng, ara) carrying one cue per second; neither subtitle is a
default. Its track ids are stable (`video/1`, `audio/2`, `audio/3`, `spu/4`,
`spu/5`).

`hls/master.m3u8` is a 10 s HLS stream: a video-only variant, two alternate
AUDIO renditions (eng, ara), and one WebVTT SUBTITLES rendition (en), all in
2 s segments except the single subtitle file. The adaptive demuxer gives every
track an unstable `<category>/auto/<n>` id and recreates a selected track under
a new id after a selection change or a seek.

Regenerate: `scripts/ci/make-track-fixtures.sh` (needs FFmpeg with libx264; set
`FFMPEG` to pick a binary). The checked-in assets are bound by SHA256SUMS;
encoder versions can change bytes.
