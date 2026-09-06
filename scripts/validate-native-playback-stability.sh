#!/usr/bin/env bash
# Integrated source contracts plus deterministic native playlist handoffs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:?VLC source root required}"
XCFRAMEWORK="${2:-}"
VLC_BUILD_ROOT="${3:-}"
python3 -B "$SCRIPT_DIR/patches/validation/native-playback-stability-source-check.py" "$VLC_SOURCE_ROOT"
if [[ -z "$XCFRAMEWORK" ]]; then exit 0; fi
ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"
if [[ ! -f "$ARCHIVE" || ! -f "$VLC_BUILD_ROOT/config.h" ]]; then
    echo "Native playback runtime validation requires a macOS archive and matching generated headers." >&2
    exit 1
fi
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-native-playback.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
compile_probe() {
clang -std=gnu17 -DHAVE_CONFIG_H \
    -I "$VLC_BUILD_ROOT" -I "$VLC_SOURCE_ROOT" \
    -I "$VLC_SOURCE_ROOT/include" -I "$VLC_SOURCE_ROOT/lib" \
    -I "$VLC_SOURCE_ROOT/src" -I "$VLC_BUILD_ROOT/include" \
    "$SCRIPT_DIR/patches/validation/$1.c" \
    "$ARCHIVE" \
    -framework AppKit -framework AudioToolbox -framework AudioUnit \
    -framework AVFoundation -framework AVKit -framework CoreAudio \
    -framework CoreFoundation -framework CoreGraphics -framework CoreImage \
    -framework CoreMedia -framework CoreServices -framework CoreText \
    -framework CoreVideo -framework Foundation -framework IOKit \
    -framework IOSurface -framework OpenGL -framework QuartzCore \
    -framework Security -framework SystemConfiguration -framework VideoToolbox \
    -lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz \
    -o "$WORK_DIR/$1"
}
compile_probe playlist-mode-handoff-probe
"$WORK_DIR/playlist-mode-handoff-probe"
compile_probe playback-recovery-eos-probe
"$WORK_DIR/playback-recovery-eos-probe" "$SCRIPT_DIR/../Tests/SwiftVLCTests/Fixtures/twosec.mp4"
