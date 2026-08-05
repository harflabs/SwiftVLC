#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.qualification-fixtures}"
DURATION_SECONDS="${SWIFTVLC_FIXTURE_DURATION_SECONDS:-60}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required to generate qualification fixtures." >&2
  exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required to verify qualification fixtures." >&2
  exit 1
fi

case "$DURATION_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_FIXTURE_DURATION_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$DURATION_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_FIXTURE_DURATION_SECONDS must be positive." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR/hls"
fixture_tmp=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-fixtures.XXXXXX")
trap 'rm -rf "$fixture_tmp"' EXIT
mkdir -p \
  "$fixture_tmp/hls/soak/ts/low" \
  "$fixture_tmp/hls/soak/ts/high" \
  "$fixture_tmp/hls/soak/fmp4/low" \
  "$fixture_tmp/hls/soak/fmp4/high" \
  "$fixture_tmp/performance" \
  "$fixture_tmp/cadence"
LIVE_DURATION_SECONDS="$DURATION_SECONDS"
if [[ "$LIVE_DURATION_SECONDS" -lt 120 ]]; then
  LIVE_DURATION_SECONDS=120
fi

ffmpeg_quiet=(ffmpeg -hide_banner -loglevel error -nostdin -y)

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -t "$DURATION_SECONDS" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 128k -movflags +faststart \
  "$fixture_tmp/vod.mp4"

"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/vod.mp4" -t "$LIVE_DURATION_SECONDS" \
  -c copy -f mpegts "$fixture_tmp/live.ts"

"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/vod.mp4" -c copy \
  -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename "$fixture_tmp/vod-%03d.ts" \
  "$fixture_tmp/vod.m3u8"

# Two real representations and both HLS segment containers back the adaptive
# soak origin. The server builds VOD, event, and sliding-live manifests from
# these deterministic files at request time, so a long run never depends on a
# third-party CDN or an expiring public stream.
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/vod.mp4" \
  -vf "scale=320:180" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a copy -movflags +faststart \
  "$fixture_tmp/low.mp4"

for variant in low high; do
  source="$fixture_tmp/vod.mp4"
  if [[ "$variant" == "low" ]]; then
    source="$fixture_tmp/low.mp4"
  fi

  "${ffmpeg_quiet[@]}" \
    -i "$source" -c copy \
    -hls_time 2 -hls_playlist_type vod \
    -hls_segment_filename "$fixture_tmp/hls/soak/ts/$variant/segment-%03d.ts" \
    "$fixture_tmp/hls/soak/ts/$variant/media.m3u8"

  (
    cd "$fixture_tmp/hls/soak/fmp4/$variant"
    "${ffmpeg_quiet[@]}" \
      -i "$source" -c copy \
      -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
      -hls_fmp4_init_filename init.mp4 \
      -hls_segment_filename "segment-%03d.m4s" \
      media.m3u8
  )
done

# Exact rational-rate fixtures for the cadence row. Encode one short source,
# then remux it into a real continuous timeline long enough for every physical
# phase. Labels avoid punctuation so they are safe in URLs and evidence keys.
cadence_specs=(
  "23_976|24000/1001"
  "24|24"
  "25|25"
  "29_97|30000/1001"
  "30|30"
  "50|50"
  "59_94|60000/1001"
  "60|60"
)
for cadence_spec in "${cadence_specs[@]}"; do
  IFS='|' read -r cadence_name cadence_rate <<< "$cadence_spec"
  cadence_short="$fixture_tmp/cadence/$cadence_name-short.mp4"
  "${ffmpeg_quiet[@]}" \
    -f lavfi -i "testsrc2=size=640x360:rate=$cadence_rate" \
    -f lavfi -i "sine=frequency=550:sample_rate=48000" \
    -t 4 -shortest \
    -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
    -g 120 -keyint_min 1 -sc_threshold 0 \
    -c:a aac -b:a 96k -movflags +faststart \
    "$cadence_short"
  "${ffmpeg_quiet[@]}" \
    -stream_loop -1 -i "$cadence_short" -t "$LIVE_DURATION_SECONDS" \
    -c copy -movflags +faststart "$fixture_tmp/cadence/$cadence_name.mp4"
  rm "$cadence_short"
done

# A single track with 24 fps then 60 fps presentation deltas. ffprobe reports
# two distinct timestamp steps; the generator rejects any toolchain behavior
# that accidentally normalizes this back to constant rate.
"${ffmpeg_quiet[@]}" \
  -f lavfi -t 2 -i "testsrc2=size=640x360:rate=24" \
  -f lavfi -t 2 -i "testsrc2=size=640x360:rate=60" \
  -f lavfi -t 4 -i "sine=frequency=550:sample_rate=48000" \
  -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' \
  -map '[v]' -map 2:a -fps_mode vfr \
  -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
  -c:a aac -b:a 96k -shortest -movflags +faststart \
  "$fixture_tmp/cadence/vfr-short.mp4"
"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/cadence/vfr-short.mp4" \
  -t "$LIVE_DURATION_SECONDS" -c copy -movflags +faststart \
  "$fixture_tmp/cadence/vfr.mp4"
rm "$fixture_tmp/cadence/vfr-short.mp4"
ffprobe -v error -select_streams v:0 \
  -show_entries frame=best_effort_timestamp_time -of csv=p=0 \
  "$fixture_tmp/cadence/vfr.mp4" \
  | python3 -c '
import sys
values = [float(line.strip().strip(",")) for line in sys.stdin if line.strip().strip(",")]
deltas = {round(second - first, 4) for first, second in zip(values, values[1:])}
if len(deltas) < 2:
    raise SystemExit("generated VFR fixture has only one presentation delta")
'

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t "$DURATION_SECONDS" -c:a aac -b:a 128k \
  "$fixture_tmp/audio.m4a"

# Short, highly compressible 60 fps sources are looped by libVLC during the
# 15-minute physical rows. They exercise the real 1080p/4K decode and BGRA
# conversion geometry without checking hundreds of megabytes into the repo or
# requiring a public CDN during qualification.
for performance_profile in 1080p60 4k60; do
  performance_size="1920x1080"
  if [[ "$performance_profile" == "4k60" ]]; then
    performance_size="3840x2160"
  fi
  "${ffmpeg_quiet[@]}" \
    -f lavfi -i "testsrc2=size=$performance_size:rate=60" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" \
    -t 6 -shortest \
    -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
    -profile:v high -level:v 5.2 -g 60 -keyint_min 60 -sc_threshold 0 \
    -c:a aac -b:a 96k -movflags +faststart \
    "$fixture_tmp/performance/$performance_profile.mp4"
  expected_probe="${performance_size/x/,},60/1"
  actual_probe=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate \
    -of csv=p=0 "$fixture_tmp/performance/$performance_profile.mp4")
  if [[ "$actual_probe" != "$expected_probe" ]]; then
    echo "Error: $performance_profile fixture probe was $actual_probe, expected $expected_probe." >&2
    exit 1
  fi
done

mv "$fixture_tmp/vod.mp4" "$OUTPUT_DIR/vod.mp4"
mv "$fixture_tmp/live.ts" "$OUTPUT_DIR/live.ts"
mv "$fixture_tmp/audio.m4a" "$OUTPUT_DIR/audio.m4a"
rm -rf "$OUTPUT_DIR/performance"
mv "$fixture_tmp/performance" "$OUTPUT_DIR/performance"
rm -rf "$OUTPUT_DIR/cadence"
mv "$fixture_tmp/cadence" "$OUTPUT_DIR/cadence"
mv "$fixture_tmp/vod.m3u8" "$OUTPUT_DIR/hls/vod.m3u8"
for segment in "$fixture_tmp"/vod-*.ts; do
  mv "$segment" "$OUTPUT_DIR/hls/$(basename "$segment")"
done
rm -rf "$OUTPUT_DIR/hls/soak"
mv "$fixture_tmp/hls/soak" "$OUTPUT_DIR/hls/soak"

python3 - "$OUTPUT_DIR/vod.mp4" "$OUTPUT_DIR/unsupported-codec.mp4" <<'PY'
import sys
from pathlib import Path

source, output = map(Path, sys.argv[1:])
payload = source.read_bytes()
if b"avc1" not in payload:
    raise SystemExit("generated VOD has no avc1 sample entry to invalidate")
output.write_bytes(payload.replace(b"avc1", b"zzzz"))
PY

python3 - "$OUTPUT_DIR" "$DURATION_SECONDS" "$LIVE_DURATION_SECONDS" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
duration = int(sys.argv[2])
live_duration = int(sys.argv[3])
vod = (root / "vod.mp4").read_bytes()
(root / "truncated.mp4").write_bytes(vod[: max(1, len(vod) // 3)])
(root / "malformed.bin").write_bytes(b"not-a-media-container\x00" * 256)
(root / "malformed.mp4").write_bytes(b"not-a-media-container\x00" * 256)

files = {}
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name != "manifest.json":
        data = path.read_bytes()
        files[str(path.relative_to(root))] = {
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }

manifest = {
    "formatVersion": 1,
    "durationSeconds": duration,
    "liveDurationSeconds": live_duration,
    "video": {"width": 640, "height": 360, "framesPerSecond": 30},
    "performance": {
        "1080p60": {"width": 1920, "height": 1080, "framesPerSecond": 60},
        "4k60": {"width": 3840, "height": 2160, "framesPerSecond": 60},
    },
    "cadence": {
        "rates": [23.976, 24, 25, 29.97, 30, 50, 59.94, 60],
        "vfr": True,
        "durationSeconds": live_duration,
    },
    "files": files,
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

echo "Generated deterministic qualification fixtures in $OUTPUT_DIR"
