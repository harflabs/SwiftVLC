#!/bin/bash
# Source/mutation/model proof plus strict Apple-target syntax for native 0032/0033.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VLC_SOURCE_ROOT="${1:-}"
VLC_BUILD_ROOT="${2:-}"
APPLE_SDK="${3:-iphoneos}"
DEPLOYMENT_TARGET="${4:-}"

usage() {
    echo "Usage: $0 <patched-vlc-source> [configured-vlc-build] [apple-sdk] [deployment-target]" >&2
    echo "  SDKs: iphoneos (default), iphonesimulator, appletvos, appletvsimulator," >&2
    echo "        xros, xrsimulator, maccatalyst, macosx" >&2
}

if [[ -z "$VLC_SOURCE_ROOT" || ! -d "$VLC_SOURCE_ROOT" ]]; then
    usage
    exit 2
fi
VLC_SOURCE_ROOT="$(cd "$VLC_SOURCE_ROOT" && pwd)"

SOURCE_CHECKER="$SCRIPT_DIR/patches/validation/audio-media-services-reset-source-check.py"
EXPECTED_SOURCE_CHECKER_SHA="ed0d4eaec115e0d93f98e69ba02ce2f3c6b6a88e1651f8b2d38bd1fa3ade756c"
ACTUAL_SOURCE_CHECKER_SHA="$(shasum -a 256 "$SOURCE_CHECKER" | awk '{print $1}')"
if [[ "$ACTUAL_SOURCE_CHECKER_SHA" != "$EXPECTED_SOURCE_CHECKER_SHA" ]]; then
    echo "Audio media-services reset validator hash mismatch:" >&2
    echo "  expected $EXPECTED_SOURCE_CHECKER_SHA" >&2
    echo "  actual   $ACTUAL_SOURCE_CHECKER_SHA" >&2
    exit 1
fi

python3 "$SOURCE_CHECKER" "$VLC_SOURCE_ROOT" "$REPOSITORY_ROOT"

if [[ -z "$VLC_BUILD_ROOT" ]]; then
    echo "Source/mutation/model proof passed; strict Apple syntax skipped (no configured build)."
    exit 0
fi
if [[ ! -f "$VLC_BUILD_ROOT/config.h" && -f "$VLC_BUILD_ROOT/build/config.h" ]]; then
    VLC_BUILD_ROOT="$VLC_BUILD_ROOT/build"
fi
if [[ ! -f "$VLC_BUILD_ROOT/config.h" ]]; then
    echo "Configured VLC build has no config.h: $VLC_BUILD_ROOT" >&2
    exit 1
fi
VLC_BUILD_ROOT="$(cd "$VLC_BUILD_ROOT" && pwd)"

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo "Source/mutation/model proof passed; strict Apple syntax requires macOS and Xcode."
    exit 0
fi

case "$APPLE_SDK" in
    iphoneos)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-18.0}"
        TARGET="arm64-apple-ios${DEPLOYMENT_TARGET}"
        ;;
    iphonesimulator)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-18.0}"
        TARGET="arm64-apple-ios${DEPLOYMENT_TARGET}-simulator"
        ;;
    appletvos)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-18.0}"
        TARGET="arm64-apple-tvos${DEPLOYMENT_TARGET}"
        ;;
    appletvsimulator)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-18.0}"
        TARGET="arm64-apple-tvos${DEPLOYMENT_TARGET}-simulator"
        ;;
    xros)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-2.0}"
        TARGET="arm64-apple-xros${DEPLOYMENT_TARGET}"
        ;;
    xrsimulator)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-2.0}"
        TARGET="arm64-apple-xros${DEPLOYMENT_TARGET}-simulator"
        ;;
    maccatalyst)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-18.0}"
        APPLE_SDK="macosx"
        TARGET="arm64-apple-ios${DEPLOYMENT_TARGET}-macabi"
        ;;
    macosx)
        DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"
        TARGET="arm64-apple-macos${DEPLOYMENT_TARGET}"
        ;;
    *)
        echo "Unsupported Apple syntax SDK: $APPLE_SDK" >&2
        usage
        exit 2
        ;;
esac

# Keep syntax caches and clang temporary files outside the source and build
# trees. Release builds set the portable validation override to external
# storage; other callers fall back to the configured build volume or TMPDIR.
VALIDATION_TMP_ROOT="${SWIFTVLC_VALIDATION_TMP_ROOT:-${SWIFTVLC_EXTERNAL_TMPDIR:-}}"
if [[ -z "$VALIDATION_TMP_ROOT" && "$VLC_BUILD_ROOT" == /Volumes/* ]]; then
    # A configured slice normally lives below the VLC source tree. Using its
    # immediate parent would therefore put clang's scratch data back inside
    # that tree and fail the isolation check below. Derive a stable scratch
    # root from the containing external volume instead.
    EXTERNAL_BUILD_PATH="${VLC_BUILD_ROOT#/Volumes/}"
    EXTERNAL_VOLUME_NAME="${EXTERNAL_BUILD_PATH%%/*}"
    VALIDATION_TMP_ROOT="/Volumes/${EXTERNAL_VOLUME_NAME}/SwiftVLC-Builds/Tmp"
fi
VALIDATION_TMP_ROOT="${VALIDATION_TMP_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$VALIDATION_TMP_ROOT"
VALIDATION_TMP_ROOT="$(cd "$VALIDATION_TMP_ROOT" && pwd)"
case "$VALIDATION_TMP_ROOT/" in
    "$REPOSITORY_ROOT/"*|"$VLC_SOURCE_ROOT/"*|"$VLC_BUILD_ROOT/"*)
        echo "Validation TMPDIR must not be inside source or build trees: $VALIDATION_TMP_ROOT" >&2
        exit 2
        ;;
esac

CLANG="$(xcrun --sdk "$APPLE_SDK" --find clang)"
SDK_ROOT="$(xcrun --sdk "$APPLE_SDK" --show-sdk-path)"
WORK_DIR="$(mktemp -d "$VALIDATION_TMP_ROOT/swiftvlc-audio-reset.XXXXXX")"
cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM
mkdir -p "$WORK_DIR/module-cache" "$WORK_DIR/clang-tmp"
export TMPDIR="$WORK_DIR/clang-tmp"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache"

COMMON=(
    -isysroot "$SDK_ROOT"
    -target "$TARGET"
    -DHAVE_CONFIG_H
    -D__IPHONEOS_VERSION_MAX_ALLOWED=999999
    -D_INTL_REDIRECT_MACROS
    -I "$VLC_BUILD_ROOT"
    -I "$VLC_BUILD_ROOT/include"
    -I "$VLC_SOURCE_ROOT"
    -I "$VLC_SOURCE_ROOT/include"
    -I "$VLC_SOURCE_ROOT/modules"
    -I "$VLC_SOURCE_ROOT/modules/access"
    -I "$VLC_SOURCE_ROOT/modules/codec"
    -I "$VLC_SOURCE_ROOT/src"
    -I "$VLC_SOURCE_ROOT/src/audio_output"
    -I "$VLC_SOURCE_ROOT/src/input"
    -I "$VLC_SOURCE_ROOT/src/player"
    -I "$VLC_SOURCE_ROOT/lib"
    -I "$VLC_SOURCE_ROOT/compat/stdbit"
    -fmodules
    -fsyntax-only
    -Wall -Wextra -Werror
    -Wno-unused-variable
    -Wno-unused-but-set-variable
    -Wno-unused-function
    -Wno-unused-parameter
    -Wno-deprecated-declarations
    -Wsign-compare -Wundef -Wpointer-arith -Wvolatile-register-var
    -Wformat -Wformat-security
)
if [[ "$TARGET" == *-macabi ]]; then
    COMMON+=(
        -iframework
        "$SDK_ROOT/System/iOSSupport/System/Library/Frameworks"
    )
fi

MODULE_COMMON=(
    '-DMODULE_STRING="audiounit_ios"'
    -DMODULE_NAME=audiounit_ios
    -Werror=partial-availability
)

echo "[1/10] Process Apple audio-session broker ($TARGET)"
"$CLANG" "${COMMON[@]}" -fobjc-arc \
    "$VLC_SOURCE_ROOT/src/darwin/apple_audio_session.m"

echo "[2/10] AVAudioSession common policy/ownership ($TARGET)"
"$CLANG" "${COMMON[@]}" "${MODULE_COMMON[@]}" \
    "$VLC_SOURCE_ROOT/modules/audio_output/apple/avaudiosession_common.m"

echo "[3/10] AudioUnit loss/reset output ($TARGET)"
"$CLANG" "${COMMON[@]}" "${MODULE_COMMON[@]}" \
    "$VLC_SOURCE_ROOT/modules/audio_output/apple/audiounit_ios.m"

echo "[4/10] Priority-100 AVSampleBuffer loss/reset output ($TARGET)"
"$CLANG" "${COMMON[@]}" -fobjc-arc \
    '-DMODULE_STRING="avsamplebuffer"' -DMODULE_NAME=avsamplebuffer \
    -Werror=partial-availability \
    "$VLC_SOURCE_ROOT/modules/audio_output/apple/avsamplebuffer.m"

echo "[5/10] Shared audio-output command control ($TARGET)"
"$CLANG" "${COMMON[@]}" -std=gnu17 \
    "$VLC_SOURCE_ROOT/src/audio_output/output.c"

echo "[6/10] Shared input_resource ownership bridge ($TARGET)"
"$CLANG" "${COMMON[@]}" -std=gnu17 \
    "$VLC_SOURCE_ROOT/src/input/resource.c"

echo "[7/10] Player audio command bridge ($TARGET)"
"$CLANG" "${COMMON[@]}" -std=gnu17 \
    "$VLC_SOURCE_ROOT/src/player/aout.c"

echo "[8/10] Player invalidation/explicit command boundaries ($TARGET)"
"$CLANG" "${COMMON[@]}" -std=gnu17 \
    "$VLC_SOURCE_ROOT/src/player/player.c"

echo "[9/10] Public libVLC Play/Resume and snapshot bridge ($TARGET)"
"$CLANG" "${COMMON[@]}" -std=gnu17 \
    "$VLC_SOURCE_ROOT/lib/media_player.c"

echo "[10/10] Media-list automatic/user authorization discriminator ($TARGET)"
"$CLANG" "${COMMON[@]}" -std=gnu17 \
    "$VLC_SOURCE_ROOT/lib/media_list_player.c"

echo "PASS audio media-services reset validation: checker_sha=$ACTUAL_SOURCE_CHECKER_SHA syntax_tus=10 sdk=$APPLE_SDK target=$TARGET tmp=$VALIDATION_TMP_ROOT"
