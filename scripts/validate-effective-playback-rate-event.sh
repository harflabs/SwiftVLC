#!/bin/bash
# Validate patch 0031's append-only effective playback-rate event contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:-}"
VLC_BUILD_ROOT="${2:-}"
XCFRAMEWORK="${3:-}"

if [[ -z "$VLC_SOURCE_ROOT" || ! -d "$VLC_SOURCE_ROOT" ]]; then
    echo "Usage: $0 <patched-vlc-source> [vlc-host-build] [xcframework]" >&2
    exit 2
fi
VLC_SOURCE_ROOT="$(cd "$VLC_SOURCE_ROOT" && pwd)"

SOURCE_CHECKER="$SCRIPT_DIR/patches/validation/effective-playback-rate-event-source-check.py"
VERSION_RESOLVER="$SCRIPT_DIR/patches/validation/pip_extension_version.py"
ABI_C="$SCRIPT_DIR/patches/validation/effective-playback-rate-event-abi.c"
ABI_CXX="$SCRIPT_DIR/patches/validation/effective-playback-rate-event-abi.cpp"
RUNTIME_PROBE="$SCRIPT_DIR/patches/validation/effective-playback-rate-event-probe.c"

verify_source() {
    local source_file="$1"
    local expected_sha="$2"
    local actual_sha
    actual_sha=$(shasum -a 256 "$source_file" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "Effective-rate validation source hash mismatch:" >&2
        echo "  $source_file" >&2
        echo "  expected $expected_sha" >&2
        echo "  actual   $actual_sha" >&2
        exit 1
    fi
}

verify_source "$SOURCE_CHECKER" \
    335a0999ce19577819df1382e8c5260876eab514a8fc460646fb4925e3de2700
verify_source "$VERSION_RESOLVER" \
    1582e0915d13a177fbe545099a1ed52696d1b60cfa5dbfd6a35a60943ccfcd36
verify_source "$ABI_C" \
    cc824316f4cd8044e5976ed36dba61a9dbaff8f2125b5ba1674f342efc5cb94b
verify_source "$ABI_CXX" \
    ded305b206534bd1324a5fb9d1d6800ba9f3e01360eca2da5e602dcaaa92a369
verify_source "$RUNTIME_PROBE" \
    e48829e8ac1402d62c12bd96d1d1953523f5c8f3978a92e716fba2d12f3d2d86

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
    echo "Effective-rate source proof passed; ABI/source compile gates require macOS and Xcode."
    exit 0
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-effective-rate.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/compiler-tmp" "$WORK_DIR/module-cache"
export TMPDIR="$WORK_DIR/compiler-tmp"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache"

CLANG=$(xcrun --sdk macosx --find clang)
CLANGXX=$(xcrun --sdk macosx --find clang++)
MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)

echo "[1/3] Public C11 event ABI"
"$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
    -I "$VLC_SOURCE_ROOT/include" "$ABI_C" -o "$WORK_DIR/rate-abi-c"
"$WORK_DIR/rate-abi-c"
"$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
    "$VERSION_DEFINE" -fsyntax-only \
    -I "$VLC_SOURCE_ROOT/include" "$RUNTIME_PROBE"

echo "[2/3] Public C++17 event ABI"
"$CLANGXX" -isysroot "$MACOS_SDK" -std=c++17 -Wall -Wextra -Werror \
    -I "$VLC_SOURCE_ROOT/include" "$ABI_CXX" -o "$WORK_DIR/rate-abi-cxx"
"$WORK_DIR/rate-abi-cxx"

if [[ -n "$VLC_BUILD_ROOT" ]]; then
    if [[ -f "$VLC_BUILD_ROOT/config.h" ]]; then
        VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT" && pwd)"
    elif [[ -f "$VLC_BUILD_ROOT/build/config.h" ]]; then
        VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT/build" && pwd)"
    else
        echo "VLC host config.h not found under: $VLC_BUILD_ROOT" >&2
        exit 1
    fi

    echo "[3/3] Exact libVLC media-player source syntax"
    "$CLANG" -isysroot "$MACOS_SDK" -std=gnu17 -DHAVE_CONFIG_H \
        -Wall -Wextra -Werror -fsyntax-only \
        -I "$VLC_BUILD_DIR" -I "$VLC_SOURCE_ROOT" \
        -I "$VLC_SOURCE_ROOT/include" -I "$VLC_SOURCE_ROOT/lib" \
        -I "$VLC_BUILD_DIR/include" \
        "$VLC_SOURCE_ROOT/lib/media_player.c"
else
    echo "[3/3] Exact media-player source syntax skipped (no configured host build)."
fi

if [[ -n "$XCFRAMEWORK" ]]; then
    ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"
    if [[ ! -f "$ARCHIVE" ]]; then
        echo "Effective-rate runtime archive not found: $ARCHIVE" >&2
        exit 1
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
    echo "[4/4] Linked idle/active effective-rate delivery and same-rate silence"
    "$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
        "$VERSION_DEFINE" -I "$VLC_SOURCE_ROOT/include" \
        "$RUNTIME_PROBE" "$ARCHIVE" \
        -o "$WORK_DIR/rate-runtime" "${FRAMEWORKS[@]}"
    "$WORK_DIR/rate-runtime" \
        "$SCRIPT_DIR/../Tests/SwiftVLCTests/Fixtures/twosec.mp4"
else
    echo "[4/4] Linked effective-rate delivery skipped (no xcframework)."
fi

echo "PASS effective playback-rate event at integrated extension version $EXPECTED_EXTENSION_VERSION: append-only public ABI, resolved-rate payload, callback wiring, and runtime version gate."
