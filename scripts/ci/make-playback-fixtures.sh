#!/bin/sh
# Regenerates Tests/SwiftVLCTests/Fixtures/playback: small media for the
# terminal-outcome, paused-time and video-output regressions of native
# patches 0065-0069.
#
# Usage: scripts/ci/make-playback-fixtures.sh [output-dir]
set -eu

out=${1:-Tests/SwiftVLCTests/Fixtures/playback}
ffmpeg=${FFMPEG:-ffmpeg}
quiet="-hide_banner -loglevel error -y"
exact="-map_metadata -1 -fflags +bitexact -flags:a +bitexact -flags:v +bitexact"
# A plain moving test card compresses to a few hundred bytes per frame.
h264="-c:v libx264 -preset veryfast -crf 36 -bf 0 -pix_fmt yuv420p"

mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1 s of video under 5 s of audio: once the video track has ended, the
# picture on screen is seconds older than the audio position.
# shellcheck disable=SC2086
$ffmpeg $quiet -f lavfi -i "testsrc=size=64x36:rate=10:duration=1" \
  -f lavfi -i "sine=frequency=440:sample_rate=16000:duration=5" \
  $h264 -g 10 -c:a aac -b:a 16k -ac 1 -movflags +faststart \
  $exact "$out/early-video-end.mp4"

# 320x136 with a 817:816 sample aspect ratio: no whole number of square
# pixels has exactly this display aspect ratio.
# shellcheck disable=SC2086
$ffmpeg $quiet -f lavfi -i "testsrc=size=320x136:rate=10:duration=2" \
  -vf "setsar=sar=817/816:max=10000" $h264 -g 10 -movflags +faststart \
  $exact "$out/inexact-sar.mp4"

# One video-only MPEG-TS program that changes from 160x90 to 320x180 after
# 2 s: the decoder keeps its video output and restarts the display in place.
# shellcheck disable=SC2086
$ffmpeg $quiet -f lavfi -i "testsrc=size=160x90:rate=30:duration=2" \
  $h264 -g 30 -bsf:v h264_mp4toannexb $exact -f mpegts "$work/a.ts"
# shellcheck disable=SC2086
$ffmpeg $quiet -f lavfi -i "testsrc=size=320x180:rate=30:duration=6" \
  $h264 -g 30 -bsf:v h264_mp4toannexb -output_ts_offset 2 $exact -f mpegts "$work/b.ts"
cat "$work/a.ts" "$work/b.ts" > "$out/resolution-switch.ts"

(cd "$out" && shasum -a 256 early-video-end.mp4 inexact-sar.mp4 resolution-switch.ts > SHA256SUMS)
