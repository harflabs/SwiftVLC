#!/usr/bin/env bash
# Generates the 2.40:1 (1920x800) test clip the aspect harness drives through
# AspectRatioCase. Content aspect must differ from the 16:9 video surface so
# letterbox vs cover vs forced-aspect are all distinguishable. testsrc2 fills
# the frame edge-to-edge with saturated colour bars (clean non-black content).
set -euo pipefail
OUT="${1:-/tmp/aspect-240.mp4}"
ffmpeg -y -f lavfi -i "testsrc2=size=1920x800:rate=15:duration=60" \
  -pix_fmt yuv420p -c:v libx264 -t 60 "$OUT"
echo "wrote $OUT"
