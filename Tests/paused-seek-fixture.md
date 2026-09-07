# Paused-seek fixture

`SwiftVLCTests/Fixtures/paused-seek.mp4` is a synthetic 20-second H.264/AAC clip
with a visible test pattern, an 880 Hz tone, and a keyframe every two seconds.
It contains no external media. The fixed GOP lets the paused-seek regression
allow a prior keyframe for fast seeking while requiring precise seeking to land
within 150 ms of its target.

Generate it from the repository root with FFmpeg:

```sh
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i testsrc2=size=160x90:rate=30 \
  -f lavfi -i sine=frequency=880:sample_rate=48000 \
  -t 20 -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p -crf 28 -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 32k -movflags +faststart \
  Tests/SwiftVLCTests/Fixtures/paused-seek.mp4
```

The test serves the checked-in clip over throttled loopback HTTP, waits while
paused, performs forward/backward/position/absolute seeks, checks both the Swift
mirror and native clock at settlement and after another pause, then resumes.
It runs with fast/precise seeking and audio enabled/disabled. Native-build CI
sets `SWIFTVLC_NATIVE_SEEK_TESTS=1` so this suite runs against the rebuilt engine
on headless runners as well.
