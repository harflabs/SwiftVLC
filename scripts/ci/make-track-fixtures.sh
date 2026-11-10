#!/bin/sh
# Regenerates Tests/SwiftVLCTests/Fixtures/tracks: small media with several
# audio and subtitle tracks for the track-selection tests.
#
# Usage: scripts/ci/make-track-fixtures.sh [output-dir]
set -eu

out=${1:-Tests/SwiftVLCTests/Fixtures/tracks}
ffmpeg=${FFMPEG:-ffmpeg}
quiet="-hide_banner -loglevel error -y"
exact="-map_metadata -1 -fflags +bitexact -flags:a +bitexact -flags:v +bitexact"
# A black 64x36 picture at 5 fps. Subtitles need it: without a video output
# libVLC's subtitle decoder waits seconds per cue for one to appear.
video="-f lavfi -i color=c=black:s=64x36:r=5:d=10"
h264="-c:v libx264 -preset ultrafast -tune stillimage -g 5 -pix_fmt yuv420p"

mkdir -p "$out/hls/video" "$out/hls/eng" "$out/hls/ara" "$out/hls/subs"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Two 10 s cue tracks: one cue per second, so a selected track always has
# a cue on screen.
i=0
: > "$work/eng.srt"
: > "$work/ara.srt"
: > "$out/hls/subs/en.vtt"
echo "WEBVTT" >> "$out/hls/subs/en.vtt"
while [ $i -lt 10 ]; do
  n=$((i + 1))
  printf '%d\n00:00:%02d,000 --> 00:00:%02d,900\nEnglish %d\n\n' "$n" "$i" "$i" "$n" >> "$work/eng.srt"
  printf '%d\n00:00:%02d,000 --> 00:00:%02d,900\nArabic %d\n\n' "$n" "$i" "$i" "$n" >> "$work/ara.srt"
  printf '\n00:00:%02d.000 --> 00:00:%02d.900\nEnglish %d\n' "$i" "$i" "$n" >> "$out/hls/subs/en.vtt"
  i=$n
done

# MKV: video, two AAC tracks (eng 440 Hz, ara 660 Hz), and two SRT tracks.
# Neither subtitle is a default, so none is selected until asked for.
# shellcheck disable=SC2086
$ffmpeg $quiet $video \
  -f lavfi -i "sine=frequency=440:sample_rate=16000:duration=10" \
  -f lavfi -i "sine=frequency=660:sample_rate=16000:duration=10" \
  -i "$work/eng.srt" -i "$work/ara.srt" \
  -map 0 -map 1 -map 2 -map 3 -map 4 \
  $h264 -c:a aac -b:a 16k -ac 1 -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=ara \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=ara \
  -disposition:s:0 0 -disposition:s:1 0 \
  $exact "$out/multitrack.mkv"

# HLS: a video-only variant with two alternate AUDIO renditions and one
# WebVTT SUBTITLES rendition. The adaptive demuxer gives every track an
# unstable "<cat>/auto/<n>" id.
# shellcheck disable=SC2086
$ffmpeg $quiet $video $h264 $exact \
  -f hls -hls_time 2 -hls_playlist_type vod \
  -hls_segment_filename "$out/hls/video/%d.ts" "$out/hls/video/index.m3u8"
for rendition in eng:440 ara:660; do
  lang=${rendition%%:*}
  frequency=${rendition##*:}
  # shellcheck disable=SC2086
  $ffmpeg $quiet \
    -f lavfi -i "sine=frequency=$frequency:sample_rate=16000:duration=10" \
    -c:a aac -b:a 16k -ac 1 $exact \
    -f hls -hls_time 2 -hls_playlist_type vod \
    -hls_segment_filename "$out/hls/$lang/%d.ts" "$out/hls/$lang/index.m3u8"
done

cat > "$out/hls/subs/index.m3u8" <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:10.0,
en.vtt
#EXT-X-ENDLIST
EOF

cat > "$out/hls/master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="eng",DEFAULT=YES,AUTOSELECT=YES,URI="eng/index.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Arabic",LANGUAGE="ara",DEFAULT=NO,AUTOSELECT=YES,URI="ara/index.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=NO,URI="subs/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=64000,RESOLUTION=64x36,CODECS="avc1.42c00a,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
video/index.m3u8
EOF

(cd "$out" && find . -type f ! -name SHA256SUMS ! -name README.md | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS)
