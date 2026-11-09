#!/bin/bash
# Generates A/V measurement fixtures: 20-bit frame-index barcode in the top band
# (block i = bit i, 32px wide, white=1), testsrc2 background, 440 Hz tone + 2 kHz
# 10 ms click at every whole second. Usage: make_fixtures.sh OUTDIR [minutes]
set -euo pipefail
OUT="$1"; SECS="${2:-1800}"; mkdir -p "$OUT"
VF="drawbox=x=0:y=0:w=640:h=72:color=black:t=fill"
for i in $(seq 0 19); do
  VF="$VF,drawbox=x=$((i*32)):y=0:w=32:h=72:color=white:t=fill:enable='mod(floor(n/pow(2\,$i))\,2)'"
done
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i "testsrc2=s=640x360:r=30" \
  -f lavfi -i "aevalsrc='0.25*sin(2*PI*440*t)+if(lt(mod(t\,1)\,0.01)\,0.6*sin(2*PI*2000*t)\,0)|0.25*sin(2*PI*440*t)+if(lt(mod(t\,1)\,0.01)\,0.6*sin(2*PI*2000*t)\,0):s=48000'" \
  -t $SECS -vf "$VF" \
  -c:v libx264 -profile:v high -preset veryfast -crf 23 -g 60 -keyint_min 60 -sc_threshold 0 -bf 3 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$OUT/av30.mp4"
mkdir -p "$OUT/hls-vod"
ffmpeg -hide_banner -loglevel error -nostdin -y -i "$OUT/av30.mp4" -c copy \
  -hls_time 4 -hls_list_size 0 -hls_playlist_type vod -hls_segment_filename "$OUT/hls-vod/seg%05d.ts" "$OUT/hls-vod/index.m3u8"
ffmpeg -hide_banner -loglevel error -nostdin -y -i "$OUT/av30.mp4" -c copy -f mpegts "$OUT/av30.ts"
echo done
