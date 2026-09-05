#!/bin/bash
# Validate SwiftVLC's additive v6 timestamp-bearing vmem callback against the
# exact patched source and, when supplied, the host archive that will ship.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VLC_SOURCE_ROOT="${1:-}"
VLC_BUILD_ROOT="${2:-}"
XCFRAMEWORK="${3:-}"

if [[ -z "$VLC_SOURCE_ROOT" || ! -d "$VLC_SOURCE_ROOT" ]]; then
    echo "Usage: $0 <patched-vlc-source> [vlc-host-build] [xcframework]" >&2
    exit 2
fi
VLC_SOURCE_ROOT="$(cd "$VLC_SOURCE_ROOT" && pwd)"

SOURCE_CHECKER="$SCRIPT_DIR/patches/validation/vmem-picture-pts-source-check.py"
VERSION_RESOLVER="$SCRIPT_DIR/patches/validation/pip_extension_version.py"
PROBE="$SCRIPT_DIR/patches/validation/vmem-picture-pts-probe.c"
ABI_CXX="$SCRIPT_DIR/patches/validation/vmem-picture-pts-abi.cpp"
RACE="$SCRIPT_DIR/patches/validation/vmem-configuration-race.c"

verify_source() {
    local source_file="$1"
    local expected_sha="$2"
    local actual_sha
    actual_sha=$(shasum -a 256 "$source_file" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "v6 vmem validation source hash mismatch:" >&2
        echo "  $source_file" >&2
        echo "  expected $expected_sha" >&2
        echo "  actual   $actual_sha" >&2
        exit 1
    fi
}

verify_source "$SOURCE_CHECKER" \
    c3d38d12de458739e95bdacdedfcd5c233b9e41ce4bab922b5142c7cc9a3e8ad
verify_source "$VERSION_RESOLVER" \
    1582e0915d13a177fbe545099a1ed52696d1b60cfa5dbfd6a35a60943ccfcd36
verify_source "$PROBE" \
    65347de5f707e49e0d2208e4c8310f84026a518ff87730c0d17eabe5757d3bb7
verify_source "$ABI_CXX" \
    b0c92e73eeb6bdf2e940a414d88f25322d99361939d6a77468891c933f1ca068
verify_source "$RACE" \
    35b2dfa2e5587b35f7b0966cb079cbaef83828ef33e97f77b9c0f426d7fde3d7

resolver_args=(--source-root "$VLC_SOURCE_ROOT")
if [[ -n "${SWIFTVLC_EXPECTED_EXTENSION_VERSION:-}" ]]; then
    resolver_args+=(
        --expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"
    )
fi
if [[ "${SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES:-no}" = yes ]]; then
    resolver_args+=(
        --require-same-version-group apple-audio-session-leases
    )
fi
EXPECTED_EXTENSION_VERSION=$(python3 "$VERSION_RESOLVER" \
    "${resolver_args[@]}")
VERSION_DEFINE="-DSWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION=$EXPECTED_EXTENSION_VERSION"

python3 "$SOURCE_CHECKER" "$VLC_SOURCE_ROOT"

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo "v6 vmem source proof passed; compile/runtime gates require macOS and Xcode."
    exit 0
fi

VALIDATION_TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR=$(mktemp -d "$VALIDATION_TMP_ROOT/swiftvlc-vmem-pts.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/compiler-tmp" "$WORK_DIR/module-cache"
export TMPDIR="$WORK_DIR/compiler-tmp"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache"

CLANG=$(xcrun --sdk macosx --find clang)
CLANGXX=$(xcrun --sdk macosx --find clang++)
MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)

echo "[1/4] Public v4/v6 callback ABI syntax (C11 and C++17)"
"$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
    -fsyntax-only -I "$VLC_SOURCE_ROOT/include" "$PROBE"
"$CLANGXX" -isysroot "$MACOS_SDK" -std=c++17 -Wall -Wextra -Werror \
    -fsyntax-only -I "$VLC_SOURCE_ROOT/include" "$ABI_CXX"

if [[ -n "$VLC_BUILD_ROOT" ]]; then
    if [[ -f "$VLC_BUILD_ROOT/config.h" ]]; then
        VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT" && pwd)"
    elif [[ -f "$VLC_BUILD_ROOT/build/config.h" ]]; then
        VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT/build" && pwd)"
    else
        echo "VLC host config.h not found under: $VLC_BUILD_ROOT" >&2
        exit 1
    fi

    COMMON_SOURCE_FLAGS=(
        -isysroot "$MACOS_SDK" -std=gnu17 -DHAVE_CONFIG_H
        -Wall -Wextra -Werror -fsyntax-only
        -I "$VLC_BUILD_DIR"
        -I "$VLC_SOURCE_ROOT"
        -I "$VLC_SOURCE_ROOT/include"
        -I "$VLC_SOURCE_ROOT/lib"
        -I "$VLC_BUILD_DIR/include"
    )

    echo "[2/4] Exact media-player and vmem source syntax"
    "$CLANG" "${COMMON_SOURCE_FLAGS[@]}" \
        "$VLC_SOURCE_ROOT/lib/media_player.c"
    "$CLANG" "${COMMON_SOURCE_FLAGS[@]}" \
        '-DMODULE_STRING="vmem"' \
        "$VLC_SOURCE_ROOT/modules/video_output/vmem.c"

    echo "[3/4] Immutable v4/v6 generation race syntax"
    "$CLANG" "${COMMON_SOURCE_FLAGS[@]}" "$RACE"
else
    echo "[2/4] Exact source syntax skipped (no configured host build)."
    echo "[3/4] Immutable generation race skipped (no configured host build)."
fi

if [[ -n "$XCFRAMEWORK" ]]; then
    ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"
    if [[ ! -f "$ARCHIVE" ]]; then
        echo "v6 vmem runtime archive not found: $ARCHIVE" >&2
        exit 1
    fi
    if [[ -z "${VLC_BUILD_DIR:-}" ]]; then
        echo "A configured VLC host build is required with an xcframework." >&2
        exit 2
    fi

    FRAMEWORKS=(
        -framework AppKit -framework AudioToolbox -framework AudioUnit
        -framework AVFoundation -framework AVKit -framework CoreAudio
        -framework CoreFoundation -framework CoreGraphics -framework CoreImage
        -framework CoreMedia -framework CoreServices -framework CoreText
        -framework CoreVideo -framework Foundation -framework IOKit
        -framework IOSurface -framework OpenGL -framework QuartzCore
        -framework Security -framework SystemConfiguration -framework VideoToolbox
        -lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz
    )

    echo "[4/4] Linked public PTS delivery and immutable-generation race"
    "$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
        "$VERSION_DEFINE" -I "$VLC_SOURCE_ROOT/include" "$PROBE" "$ARCHIVE" \
        -o "$WORK_DIR/pts-probe" "${FRAMEWORKS[@]}"
    "$WORK_DIR/pts-probe" \
        "$REPO_ROOT/Tests/SwiftVLCTests/Fixtures/twosec.mp4"

    "$CLANG" -isysroot "$MACOS_SDK" -std=gnu17 -DHAVE_CONFIG_H \
        -Wall -Wextra -Werror \
        -I "$VLC_BUILD_DIR" -I "$VLC_SOURCE_ROOT/include" \
        -I "$VLC_BUILD_DIR/include" \
        "$RACE" "$ARCHIVE" -o "$WORK_DIR/vmem-race" "${FRAMEWORKS[@]}"
    "$WORK_DIR/vmem-race"
else
    echo "[4/4] Linked public PTS delivery skipped (no xcframework)."
fi

cat <<EOF
PASS v6 vmem picture-PTS contract at integrated extension version
$EXPECTED_EXTENSION_VERSION: v4 ABI preserved, v6 tuple publication is
atomic, vout-selected output-attempt timestamps are origin-normalized, and invalid PTS is
propagated as INT64_MIN without rejecting the picture.
EOF
