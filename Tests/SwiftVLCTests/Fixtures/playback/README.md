# Playback outcome fixtures

Original synthetic media generated for SwiftVLC; no third-party content.

`early-video-end.mp4` has 1 s of 64x36 video under 5 s of audio. After the
video track ends, the picture on screen is seconds older than the audio
position: pausing must not move the playback time back to it (patch 0066).

`inexact-sar.mp4` is 320x136 with a 817:816 sample aspect ratio. No whole
number of square pixels has exactly that display aspect ratio, so the extended
vmem output must accept the nearest pixel (patch 0067).

`resolution-switch.ts` is one video-only MPEG-TS program that changes from
160x90 to 320x180 after 2 s. The decoder keeps its video output and restarts
the display in place, which must keep the playback rate (patch 0069).

Regenerate: `scripts/ci/make-playback-fixtures.sh` (needs FFmpeg with libx264;
set `FFMPEG` to pick a binary). The checked-in assets are bound by SHA256SUMS;
encoder versions can change bytes.
