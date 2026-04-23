#!/bin/bash
# build-libvlc.sh — Compiles libVLC from official VLC source for Apple platforms
# Produces: Vendor/libvlc.xcframework (static library + C headers)
#
# Prerequisites:
#   - Xcode command line tools
#   - Python 3
#   - autoconf, automake, libtool (brew install autoconf automake libtool)
#   - gas-preprocessor (installed automatically by VLC build system)
#
# Usage:
#   ./build-libvlc.sh              # Build for iOS device + simulator
#   ./build-libvlc.sh --all        # Build for iOS, tvOS, macOS, Catalyst
#   ./build-libvlc.sh --ios-only   # iOS device + simulator only
#   ./build-libvlc.sh --macos-only # macOS only (fastest for dev)
#   ./build-libvlc.sh --catalyst   # Add Mac Catalyst (arm64 + x86_64)
#   ./build-libvlc.sh --clean      # Remove build directory
#   ./build-libvlc.sh --hash=abc   # Pin to a specific VLC commit

set -e

# --- Error trap for better failure reporting ---
trap 'error "Build failed at line $LINENO (exit code $?)"' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build-libvlc"
OUTPUT_DIR="${REPO_ROOT}/Vendor"
VLC_REPO="https://code.videolan.org/videolan/vlc.git"
VLC_BRANCH="master"
# Pin to a known-good commit for reproducible builds (same as VLCKit)
# Update this hash when upgrading libVLC
VLC_HASH="c833c4be0"

# Directory containing patches from VLCKit (optional, user must opt in)
PATCHES_DIR=""

BUILD_IOS=yes
BUILD_TVOS=no
BUILD_MACOS=no
BUILD_CATALYST=no

# Keep these deployment targets in sync with Package.swift.
SWIFTVLC_MIN_IOS="18.0"
SWIFTVLC_MIN_TVOS="18.0"
SWIFTVLC_MIN_MACOS="15.0"
SWIFTVLC_MIN_CATALYST="18.0"

BUILD_START_TIME=$(date +%s)

if [ -z "$MAKEFLAGS" ]; then
    MAKEFLAGS="-j$(sysctl -n machdep.cpu.core_count || nproc)"
fi

# --- Terminal color support ---
# Guard tput calls for non-terminal contexts (CI runners, piped output)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    COLOR_GREEN=$(tput setaf 2)
    COLOR_RED=$(tput setaf 1)
    COLOR_YELLOW=$(tput setaf 3)
    COLOR_RESET=$(tput sgr0)
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_RESET=""
fi

elapsed() {
    local now=$(date +%s)
    local secs=$((now - BUILD_START_TIME))
    local mins=$((secs / 60))
    local remaining_secs=$((secs % 60))
    printf "%dm%02ds" "$mins" "$remaining_secs"
}

info() {
    echo "[${COLOR_GREEN}info${COLOR_RESET}] [$(elapsed)] $1"
}

warn() {
    echo "[${COLOR_YELLOW}warn${COLOR_RESET}] [$(elapsed)] $1" >&2
}

error() {
    echo "[${COLOR_RED}error${COLOR_RESET}] [$(elapsed)] $1" >&2
    exit 1
}

# --- Prerequisite validation ---
# Maps a missing command to the Homebrew formula that provides it.
# Keep in sync with the `for cmd` loop in check_prerequisites.
brew_formula_for() {
    case "$1" in
        autoconf|automake|libtool|cmake|pkg-config|gettext|nasm|meson|ninja)
            echo "$1" ;;
        autopoint) echo "gettext" ;;
        python3) echo "python@3" ;;
        *) echo "$1" ;;
    esac
}

check_prerequisites() {
    # Xcode itself (not just the Command Line Tools) is required because the
    # final step uses `xcodebuild -create-xcframework`. CLT ships xcode-select
    # but not xcodebuild.
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "${COLOR_RED}Error: Xcode / Command Line Tools not installed.${COLOR_RESET}" >&2
        echo "  Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
        exit 1
    fi
    if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
        echo "${COLOR_RED}Error: xcodebuild not available.${COLOR_RESET}" >&2
        echo "  This usually means xcode-select points at Command Line Tools only." >&2
        echo "  Install the full Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
        exit 1
    fi

    # Tools needed on the host. VLC's extras/tools bootstraps its own copies of
    # nasm, meson, ninja, m4, bison, libtool — those don't need to be pre-installed.
    # What we check here is the minimum set required BEFORE extras/tools can run
    # and for autoreconf to succeed (gettext macros via autopoint) and for contribs
    # that use cmake / pkg-config.
    local required=(autoconf automake libtool autopoint pkg-config cmake python3)
    local missing=()

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "${COLOR_RED}Error: Missing required tools: ${missing[*]}${COLOR_RESET}" >&2
        echo "" >&2
        echo "  Install with:" >&2
        # Deduplicate formula names (autopoint → gettext, so both map to gettext).
        local formulas=()
        for cmd in "${missing[@]}"; do
            local f
            f=$(brew_formula_for "$cmd")
            local seen=0
            for existing in "${formulas[@]}"; do
                [ "$existing" = "$f" ] && seen=1 && break
            done
            [ "$seen" = 0 ] && formulas+=("$f")
        done
        echo "    brew install ${formulas[*]}" >&2
        echo "" >&2
        echo "  If autopoint is still missing after installing gettext, run:" >&2
        echo "    brew link --force gettext" >&2
        echo "" >&2
        exit 1
    fi
}

# --- Disk space check ---
check_disk_space() {
    local required_gb=40
    local available_kb
    available_kb=$(df -k "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [ "$available_gb" -lt "$required_gb" ]; then
        warn "Low disk space: ${available_gb}GB available, ~${required_gb}GB recommended for a full build."
        warn "The build may fail if disk space runs out."
    fi
}

# --- Parse arguments ---
for arg in "$@"; do
    case $arg in
        --all)
            BUILD_IOS=yes
            BUILD_TVOS=yes
            BUILD_MACOS=yes
            BUILD_CATALYST=yes
            ;;
        --ios-only)
            BUILD_IOS=yes
            BUILD_TVOS=no
            BUILD_MACOS=no
            ;;
        --tvos)
            BUILD_TVOS=yes
            ;;
        --macos)
            BUILD_MACOS=yes
            ;;
        --macos-only)
            BUILD_IOS=no
            BUILD_TVOS=no
            BUILD_MACOS=yes
            ;;
        --tvos-only)
            BUILD_IOS=no
            BUILD_TVOS=yes
            BUILD_MACOS=no
            ;;
        --catalyst)
            BUILD_CATALYST=yes
            ;;
        --catalyst-only)
            BUILD_IOS=no
            BUILD_TVOS=no
            BUILD_MACOS=no
            BUILD_CATALYST=yes
            ;;
        --clean)
            echo "Removing build directory: ${BUILD_DIR}"
            rm -rf "${BUILD_DIR}"
            echo "Done."
            exit 0
            ;;
        --clean-build)
            echo "Removing build directory: ${BUILD_DIR}"
            rm -rf "${BUILD_DIR}"
            echo "Continuing with fresh build..."
            ;;
        --hash=*)
            VLC_HASH="${arg#--hash=}"
            if [ -z "$VLC_HASH" ]; then
                echo "Error: --hash requires a commit hash value" >&2
                exit 1
            fi
            ;;
        --patches-dir=*)
            PATCHES_DIR="${arg#--patches-dir=}"
            if [ ! -d "$PATCHES_DIR" ]; then
                echo "Error: Patches directory not found: ${PATCHES_DIR}" >&2
                exit 1
            fi
            ;;
        --help)
            cat <<HELPEOF
Usage: $0 [OPTIONS]

Platform selection:
  --all              Build for iOS, tvOS, macOS, and Mac Catalyst
  --ios-only         iOS device + simulator only (default)
  --macos-only       macOS only (fastest for development)
  --tvos-only        tvOS device + simulator only
  --catalyst-only    Mac Catalyst only
  --tvos             Add tvOS to the build
  --macos            Add macOS to the build
  --catalyst         Add Mac Catalyst to the build

Build options:
  --clean            Remove the build directory and exit
  --clean-build      Remove the build directory, then build
  --hash=COMMIT      Pin to a specific VLC commit (default: ${VLC_HASH})
  --patches-dir=DIR  Directory containing .patch files to apply

Other:
  --help             Show this help message

Examples:
  $0                          # Build for iOS (default)
  $0 --macos-only             # Quick macOS build for development
  $0 --all                    # Full build for all platforms
  $0 --hash=abc123 --all      # Build all platforms from a specific commit
  $0 --clean-build --all      # Fresh build for all platforms
HELPEOF
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '${arg}'" >&2
            echo "Run '$0 --help' for usage information." >&2
            exit 1
            ;;
    esac
done

# --- Run startup checks ---
check_prerequisites
check_disk_space

# Normalize architecture name for directory naming
# VLC's build.sh accepts "aarch64" but creates "arm64" directories internally
get_actual_arch() {
    if [ "$1" = "aarch64" ]; then
        echo "arm64"
    else
        echo "$1"
    fi
}

# Patch VLC's build system to support Mac Catalyst builds.
# Catalyst uses the macOS SDK with the clang target triple
# arm64-apple-ios{version}-macabi, which VLC doesn't support natively.
# This function modifies build.sh and build.conf in-place (safe because
# the VLC source is reset to a pinned hash on each run).
patch_vlc_for_catalyst() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"

    if grep -q "VLC_BUILD_CATALYST" "$BUILD_SH"; then
        info "VLC build.sh already patched for Catalyst"
        return 0
    fi

    info "Patching VLC build system for Mac Catalyst support..."

    python3 - "$BUILD_SH" "$BUILD_CONF" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]
build_conf_path = sys.argv[2]

# --- Patch build.conf: add Catalyst deployment target ---
with open(build_conf_path, 'a') as f:
    f.write('\n# Mac Catalyst deployment target\n')
    f.write('export VLC_DEPLOYMENT_TARGET_CATALYST="18.0"\n')

# --- Patch build.sh ---
with open(build_sh_path, 'r') as f:
    content = f.read()

# 1. Add VLC_BUILD_CATALYST=0 global variable
content = content.replace(
    'VLC_BUILD_EXTRA_CHECKS=0\n',
    'VLC_BUILD_EXTRA_CHECKS=0\n'
    '# Whether building for Mac Catalyst\n'
    'VLC_BUILD_CATALYST=0\n',
    1
)

# 2. Add --catalyst) argument parsing case
content = content.replace(
    '        --enable-extra-checks)\n'
    '            VLC_BUILD_EXTRA_CHECKS=1\n'
    '            ;;',
    '        --enable-extra-checks)\n'
    '            VLC_BUILD_EXTRA_CHECKS=1\n'
    '            ;;\n'
    '        --catalyst)\n'
    '            VLC_BUILD_CATALYST=1\n'
    '            ;;'
)

# 3. Add Catalyst override block after set_build_triplet, before readonly declarations
content = content.replace(
    'set_build_triplet\n'
    '\n'
    '# Set pseudo-triplet',
    'set_build_triplet\n'
    '\n'
    '# Mac Catalyst: override platform settings to use macabi target triple\n'
    'if [ "$VLC_BUILD_CATALYST" -gt "0" ]; then\n'
    '    VLC_HOST_PLATFORM="macCatalyst"\n'
    '    VLC_HOST_OS="ios"\n'
    '    VLC_DEPLOYMENT_TARGET="${VLC_DEPLOYMENT_TARGET_CATALYST:-16.0}"\n'
    '    VLC_DEPLOYMENT_TARGET_CFLAG="--target=${VLC_HOST_ARCH}-apple-ios${VLC_DEPLOYMENT_TARGET}-macabi"\n'
    '    VLC_DEPLOYMENT_TARGET_LDFLAG="${VLC_DEPLOYMENT_TARGET_CFLAG}"\n'
    '    VLC_APPLE_SDK_NAME="maccatalyst${VLC_DEPLOYMENT_TARGET}"\n'
    'fi\n'
    '\n'
    '# Set pseudo-triplet'
)

# 4. Add iOSSupport framework path in set_host_envvars()
#    (unique context: followed by "local bitcode_flag")
content = content.replace(
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '    local bitcode_flag=""',
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '    if [ "${VLC_BUILD_CATALYST:-0}" -gt "0" ]; then\n'
    '        clike_flags+=" -iframework ${VLC_APPLE_SDK_PATH}/System/iOSSupport/System/Library/Frameworks"\n'
    '    fi\n'
    '    local bitcode_flag=""'
)

# 5. Add iOSSupport framework path in write_config_mak()
#    (unique context: followed by blank line then "local vlc_cppflags")
content = content.replace(
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '\n'
    '    local vlc_cppflags',
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '    if [ "${VLC_BUILD_CATALYST:-0}" -gt "0" ]; then\n'
    '        clike_flags+=" -iframework ${VLC_APPLE_SDK_PATH}/System/iOSSupport/System/Library/Frameworks"\n'
    '    fi\n'
    '\n'
    '    local vlc_cppflags'
)

# NOTE: The previous patches #6 and #7 used to conditionally add
# VLC_DEPLOYMENT_TARGET_CFLAG to CPPFLAGS for Catalyst only. That fix is now
# unconditional (all platforms) via patch_vlc_cppflags_version_min below,
# since contrib CFLAGS overrides (notably gsm) leak the host SDK's default
# minos into every simulator/device build, not just Catalyst.

# 6. Add Catalyst-specific VLC configure options (disable GLES2/EGL
#    since OpenGLES is not available on Mac Catalyst)
content = content.replace(
    'if [ "$VLC_DISABLE_DEBUG" -gt "0" ]; then\n'
    '    VLC_CONFIG_OPTIONS+=( "--disable-debug" )',
    'if [ "$VLC_BUILD_CATALYST" -gt "0" ]; then\n'
    '    VLC_CONFIG_OPTIONS+=( "--disable-gles2" )\n'
    'fi\n'
    '\n'
    'if [ "$VLC_DISABLE_DEBUG" -gt "0" ]; then\n'
    '    VLC_CONFIG_OPTIONS+=( "--disable-debug" )'
)

# 6b. Add Catalyst-specific module removal list. Modules wrapped in
#     #if !TARGET_OS_MACCATALYST compile to empty .a files that would
#     crash the static module list generator.
content = content.replace(
    'elif [ "$VLC_HOST_OS" = "watchos" ]; then\n'
    '    VLC_MODULE_REMOVAL_LIST+=( "${VLC_MODULE_REMOVAL_LIST_WATCHOS[@]}" )\n'
    'fi',
    'elif [ "$VLC_HOST_OS" = "watchos" ]; then\n'
    '    VLC_MODULE_REMOVAL_LIST+=( "${VLC_MODULE_REMOVAL_LIST_WATCHOS[@]}" )\n'
    'fi\n'
    '\n'
    'if [ "$VLC_BUILD_CATALYST" -gt "0" ]; then\n'
    '    VLC_MODULE_REMOVAL_LIST+=( "caeagl_ios" "cvpx_gl" )\n'
    'fi'
)

# 7. Patch gl_common.h to treat Catalyst like macOS for OpenGL includes.
#    On Catalyst, TARGET_OS_IPHONE=1 but OpenGLES headers are unavailable.
#    Using macOS OpenGL headers allows GL modules to compile (they may not
#    initialize at runtime, but VLC falls back to other video outputs).
gl_common_path = build_sh_path.replace(
    'extras/package/apple/build.sh',
    'modules/video_output/opengl/gl_common.h'
)
try:
    with open(gl_common_path, 'r') as f:
        gl_content = f.read()
    gl_content = gl_content.replace(
        '# if !TARGET_OS_IPHONE',
        '# if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST'
    )
    with open(gl_common_path, 'w') as f:
        f.write(gl_content)
    print('Patched gl_common.h for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch gl_common.h: {e}')

with open(build_sh_path, 'w') as f:
    f.write(content)

# 8. Patch interop_cvpx.m: On Catalyst, TARGET_OS_IPHONE=1 but OpenGLES
#     is unavailable. Replace ALL #if TARGET_OS_IPHONE guards so Catalyst
#     takes the macOS (CGL/IOSurface) code path instead of the EAGL path.
modules_dir = build_sh_path.replace('extras/package/apple/build.sh', 'modules/')
interop_path = modules_dir + 'video_output/opengl/interop_cvpx.m'
try:
    with open(interop_path, 'r') as f:
        ic = f.read()
    ic = ic.replace(
        '#if TARGET_OS_IPHONE',
        '#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST'
    )
    with open(interop_path, 'w') as f:
        f.write(ic)
    print('Patched interop_cvpx.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch interop_cvpx.m: {e}')

# 9. Patch VLCCVOpenGLProvider.m: both CVOpenGLES (iOS) and CVOpenGL (macOS)
#     texture cache APIs are API_UNAVAILABLE(macCatalyst). Disable the entire
#     module on Catalyst — VLC will use other video output paths (Metal/CALayer).
cvgl_path = modules_dir + 'video_output/apple/VLCCVOpenGLProvider.m'
try:
    with open(cvgl_path, 'r') as f:
        cc = f.read()
    cc = '#include <TargetConditionals.h>\n#if !TARGET_OS_MACCATALYST\n' + cc + '\n#endif /* !TARGET_OS_MACCATALYST */\n'
    with open(cvgl_path, 'w') as f:
        f.write(cc)
    print('Patched VLCCVOpenGLProvider.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch VLCCVOpenGLProvider.m: {e}')

# 10. Patch VLCOpenGLES2VideoView.m: entire file is EAGL/OpenGLES iOS view.
#     Wrap everything in #if !TARGET_OS_MACCATALYST so it compiles to empty .o
eagl_path = modules_dir + 'video_output/apple/VLCOpenGLES2VideoView.m'
try:
    with open(eagl_path, 'r') as f:
        ec = f.read()
    ec = '#include <TargetConditionals.h>\n#if !TARGET_OS_MACCATALYST\n' + ec + '\n#endif /* !TARGET_OS_MACCATALYST */\n'
    with open(eagl_path, 'w') as f:
        f.write(ec)
    print('Patched VLCOpenGLES2VideoView.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch VLCOpenGLES2VideoView.m: {e}')

# 11. Patch ci_filters.m: uses #if !TARGET_OS_IPHONE for CGL vs EAGL.
#     On Catalyst, we want the CGL (macOS) path since OpenGLES is unavailable.
ci_path = modules_dir + 'video_filter/ci_filters.m'
try:
    with open(ci_path, 'r') as f:
        cf = f.read()
    cf = cf.replace(
        '#if !TARGET_OS_IPHONE\n    CGLContextObj',
        '#if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST\n    CGLContextObj'
    )
    cf = cf.replace(
        '#if !TARGET_OS_IPHONE\n        CGLPixelFormatAttribute',
        '#if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST\n        CGLPixelFormatAttribute'
    )
    cf = cf.replace(
        '#if !TARGET_OS_IPHONE\n    if (ctx->cgl_context)',
        '#if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST\n    if (ctx->cgl_context)'
    )
    with open(ci_path, 'w') as f:
        f.write(cf)
    print('Patched ci_filters.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch ci_filters.m: {e}')

# 12. Patch decoder.c (videotoolbox): kCVPixelBufferOpenGLESCompatibilityKey
#     is API_UNAVAILABLE(macCatalyst). Add !TARGET_OS_MACCATALYST guard.
decoder_path = modules_dir + 'codec/videotoolbox/decoder.c'
try:
    with open(decoder_path, 'r') as f:
        dc = f.read()
    dc = dc.replace(
        '#elif !defined(TARGET_OS_VISION) || !TARGET_OS_VISION\n'
        '    CFDictionarySetValue(destinationPixelBufferAttributes,\n'
        '                         kCVPixelBufferOpenGLESCompatibilityKey,',
        '#elif (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION) && !TARGET_OS_MACCATALYST\n'
        '    CFDictionarySetValue(destinationPixelBufferAttributes,\n'
        '                         kCVPixelBufferOpenGLESCompatibilityKey,'
    )
    with open(decoder_path, 'w') as f:
        f.write(dc)
    print('Patched decoder.c for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch decoder.c: {e}')

# 13. Patch VLCSampleBufferDisplay.m: same kCVPixelBufferOpenGLESCompatibilityKey
#     issue, but uses matched arrays (keys[] and values[]) that must stay in sync.
sbd_path = modules_dir + 'video_output/apple/VLCSampleBufferDisplay.m'
try:
    with open(sbd_path, 'r') as f:
        sc = f.read()
    # Fix keys array: skip OpenGLES key on Catalyst
    sc = sc.replace(
        '#elif !defined(TARGET_OS_VISION) || !TARGET_OS_VISION\n'
        '            kCVPixelBufferOpenGLESCompatibilityKey,',
        '#elif (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION) && !TARGET_OS_MACCATALYST\n'
        '            kCVPixelBufferOpenGLESCompatibilityKey,'
    )
    # Fix values array: skip matching value on Catalyst to keep arrays in sync
    sc = sc.replace(
        '#if !defined(TARGET_OS_VISION) || !TARGET_OS_VISION\n'
        '            kCFBooleanTrue\n'
        '#endif',
        '#if (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION) && !TARGET_OS_MACCATALYST\n'
        '            kCFBooleanTrue\n'
        '#endif'
    )
    with open(sbd_path, 'w') as f:
        f.write(sc)
    print('Patched VLCSampleBufferDisplay.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch VLCSampleBufferDisplay.m: {e}')

print('Catalyst patches applied successfully')
PYEOF

    info "VLC build system patched for Mac Catalyst"
}

# --- Step 1: Clone VLC source ---
info "Setting up VLC source..."
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ ! -d "vlc" ]; then
    info "Cloning VLC from ${VLC_REPO}..."
    git clone "${VLC_REPO}" --branch "${VLC_BRANCH}" --single-branch vlc
    cd vlc
    git checkout -B build "${VLC_HASH}"
    cd ..
else
    cd vlc
    # Only reset if HEAD isn't already at the pinned commit. An unconditional
    # `git reset --hard` wipes our in-tree patches every run, forcing every
    # downstream patch function to re-apply and all per-platform build dirs
    # to rebuild. VideoLAN's GitLab also doesn't allow fetching by raw SHA,
    # so skip the fetch unless the commit is missing locally.
    CURRENT_HEAD=$(git rev-parse --verify HEAD 2>/dev/null || echo "")
    TARGET_SHA=$(git rev-parse --verify "${VLC_HASH}^{commit}" 2>/dev/null || echo "")
    if [ -z "$TARGET_SHA" ]; then
        info "Commit ${VLC_HASH} missing locally; fetching..."
        git fetch origin "${VLC_BRANCH}"
        TARGET_SHA=$(git rev-parse --verify "${VLC_HASH}^{commit}")
    fi
    if [ "$CURRENT_HEAD" != "$TARGET_SHA" ]; then
        info "VLC source at wrong commit, resetting to ${VLC_HASH}..."
        git reset --hard "${VLC_HASH}"
    else
        info "VLC source already at ${VLC_HASH}"
    fi
    cd ..
fi

VLC_SRC="${BUILD_DIR}/vlc"

# --- Step 1b: Apply patches ---
if [ -n "${PATCHES_DIR}" ] && [ -d "${PATCHES_DIR}" ]; then
    info "Applying patches from ${PATCHES_DIR}..."
    cd "${VLC_SRC}"
    for patch in "${PATCHES_DIR}"/*.patch; do
        if [ -f "$patch" ]; then
            patch_name=$(basename "$patch")
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch"
                info "  Applied: ${patch_name}"
            else
                info "  Skipped (already applied or conflicts): ${patch_name}"
            fi
        fi
    done
    cd "${BUILD_DIR}"
fi

# --- Step 1c: Patch VLC for Mac Catalyst support ---
if [ "$BUILD_CATALYST" = "yes" ]; then
    patch_vlc_for_catalyst
fi

# --- Step 1d: Patch LDFLAGS to include -isysroot ---
# On newer Xcode versions (26+), the linker requires an explicit -isysroot
# to find system libraries (libSystem, etc.). VLC's build.sh omits this from
# LDFLAGS, causing FFmpeg's configure (and others) to fail with:
#   ld: library 'System' not found
patch_vlc_ldflags() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"

    if grep -q 'LDFLAGS=.*-isysroot.*VLC_APPLE_SDK_PATH' "$BUILD_SH"; then
        info "VLC build.sh LDFLAGS already patched"
        return 0
    fi

    info "Patching VLC build.sh to add -isysroot to LDFLAGS..."

    python3 - "$BUILD_SH" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]

with open(build_sh_path, 'r') as f:
    content = f.read()

# 1. Fix LDFLAGS in set_host_envvars(): add -isysroot $VLC_APPLE_SDK_PATH
content = content.replace(
    '    export LDFLAGS="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH ${bitcode_flag}"',
    '    export LDFLAGS="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH ${bitcode_flag}"'
)

# 2. Fix vlc_ldflags in write_config_mak(): add -isysroot $VLC_APPLE_SDK_PATH
content = content.replace(
    '    local vlc_ldflags="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG  -arch $VLC_HOST_ARCH"',
    '    local vlc_ldflags="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG  -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"'
)

with open(build_sh_path, 'w') as f:
    f.write(content)

print('LDFLAGS patched successfully')
PYEOF

    info "VLC build.sh LDFLAGS patched"
}

patch_vlc_ldflags

# Propagate VLC_DEPLOYMENT_TARGET_CFLAG through CPPFLAGS so contribs that
# override CFLAGS (notably `gsm` — see contrib/src/gsm/rules.mak, which sets
# its own CFLAGS via the `Makefile` overrides shipped with the gsm source)
# still receive the platform version-min flag. Without this, those contribs
# compile with the host SDK's default minos, producing LC_BUILD_VERSION
# entries like `minos 26.4` inside a library meant for deployment target
# 18.0 — the linker then warns "built for newer 'X' version than being linked".
#
# autotools and most contrib Makefiles pass CPPFLAGS to the compiler alongside
# CFLAGS, so adding the flag here survives a CFLAGS-override in a contrib.
patch_vlc_cppflags_version_min() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"

    # Use a fixed-string (-F) check tied to this patch's exact output, so an
    # older Catalyst-only variant (which wrote `CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG $CPPFLAGS"`
    # inside an `if` block) doesn't false-positive and skip the unconditional
    # fix that device + simulator + macOS slices need.
    if grep -qF 'export CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG -arch' "$BUILD_SH"; then
        info "VLC build.sh CPPFLAGS already patched for version-min"
        return 0
    fi

    info "Patching VLC build.sh to add version-min to CPPFLAGS..."

    python3 - "$BUILD_SH" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]

with open(build_sh_path, 'r') as f:
    content = f.read()

# set_host_envvars(): CPPFLAGS used by contribs that inherit the exported env.
before = (
    '    export CPPFLAGS="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
after = (
    '    export CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
if before not in content:
    raise SystemExit('set_host_envvars CPPFLAGS line not found — VLC build.sh shape changed')
content = content.replace(before, after, 1)

# write_config_mak(): vlc_cppflags written into config.mak for contribs that
# consume the mak file directly instead of the exported env.
before = (
    '    local vlc_cppflags="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
after = (
    '    local vlc_cppflags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
if before not in content:
    raise SystemExit('write_config_mak vlc_cppflags line not found — VLC build.sh shape changed')
content = content.replace(before, after, 1)

with open(build_sh_path, 'w') as f:
    f.write(content)

print('CPPFLAGS version-min patched successfully')
PYEOF

    info "VLC build.sh CPPFLAGS patched"
}

patch_vlc_cppflags_version_min

patch_vlc_deployment_targets() {
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"

    info "Patching VLC deployment targets to match SwiftVLC's supported minimums..."

    python3 - "$BUILD_CONF" \
        "$SWIFTVLC_MIN_MACOS" \
        "$SWIFTVLC_MIN_IOS" \
        "$SWIFTVLC_MIN_TVOS" \
        "$SWIFTVLC_MIN_CATALYST" << 'PYEOF'
import re
import sys

build_conf_path, macos, ios, tvos, catalyst = sys.argv[1:]

with open(build_conf_path, 'r') as f:
    content = f.read()

replacements = {
    r'^export VLC_DEPLOYMENT_TARGET_MACOSX=.*$': f'export VLC_DEPLOYMENT_TARGET_MACOSX="{macos}"',
    r'^export VLC_DEPLOYMENT_TARGET_IOS=.*$': f'export VLC_DEPLOYMENT_TARGET_IOS="{ios}"',
    r'^export VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR=.*$': f'export VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR="{ios}"',
    r'^export VLC_DEPLOYMENT_TARGET_TVOS=.*$': f'export VLC_DEPLOYMENT_TARGET_TVOS="{tvos}"',
    r'^export VLC_DEPLOYMENT_TARGET_TVOS_SIMULATOR=.*$': f'export VLC_DEPLOYMENT_TARGET_TVOS_SIMULATOR="{tvos}"',
}

for pattern, replacement in replacements.items():
    content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

if re.search(r'^export VLC_DEPLOYMENT_TARGET_CATALYST=.*$', content, flags=re.MULTILINE):
    content = re.sub(
        r'^export VLC_DEPLOYMENT_TARGET_CATALYST=.*$',
        f'export VLC_DEPLOYMENT_TARGET_CATALYST="{catalyst}"',
        content,
        flags=re.MULTILINE
    )

with open(build_conf_path, 'w') as f:
    f.write(content)

print('Deployment targets patched successfully')
PYEOF

    info "VLC deployment targets patched"
}

patch_vlc_deployment_targets

# --- Step 1e: Force libtool --tag=CC for Objective-C convenience library ---
# VLC's src/Makefile.am builds libvlccore_objc.la from .m files, but doesn't
# tell libtool which tag to use. On libtool 2.5+ (current Homebrew), libtool
# can't infer the tag from the compile command and fails with:
#   libtool: compile: unable to infer tagged configuration
#   libtool:   error: specify a tag with '--tag'
# Older libtool versions were more permissive. LT_LANG([Objective C]) isn't a
# thing (libtool only supports C/CXX/F77/FC/GCJ/RC), so the right fix is to
# set per-target LIBTOOLFLAGS so automake emits `libtool --tag=CC` for the
# .m compiles. Objective C is a C superset; --tag=CC is exactly right.
patch_vlc_objc_libtool() {
    # Content-based idempotency: `git reset --hard` wipes our edits but leaves
    # marker files intact, so the check must look at actual file contents.
    if grep -q 'libvlccore_objc_la_LIBTOOLFLAGS' "${VLC_SRC}/src/Makefile.am"; then
        info "VLC Makefile.am files already patched for OBJC libtool tag"
        return 0
    fi

    info "Scanning Makefile.am files for .m sources to add --tag=CC..."

    python3 - "$VLC_SRC" << 'PYEOF'
import re
import sys
from pathlib import Path

vlc_root = Path(sys.argv[1])
patched = 0

# Matches "target_name_SOURCES = ..." or "target_name_SOURCES += ..."
# The RHS may span multiple lines via backslash-newline continuations.
sources_re = re.compile(
    r'^([A-Za-z_][A-Za-z0-9_]*?)_SOURCES\s*\+?=\s*((?:[^\n\\]|\\\n|\\.)*)',
    re.MULTILINE
)

for mf in sorted(vlc_root.rglob('Makefile.am')):
    # Skip the build-tools tree and anything under contribs
    if 'extras/tools' in str(mf) or 'contrib/' in str(mf):
        continue

    text = mf.read_text()
    targets_with_m = set()

    for m in sources_re.finditer(text):
        target = m.group(1)
        rhs = m.group(2)
        # Flatten line continuations
        rhs_flat = re.sub(r'\\\n', ' ', rhs)
        # A source ending in .m (not .mm for C++) — and not part of .mk/.mo etc.
        if re.search(r'(^|\s)[^\s]+\.m(\s|$)', rhs_flat):
            targets_with_m.add(target)

    if not targets_with_m:
        continue

    additions = []
    for target in sorted(targets_with_m):
        tag_re = re.compile(
            rf'^{re.escape(target)}_LIBTOOLFLAGS\s*=', re.MULTILINE
        )
        if tag_re.search(text):
            continue
        additions.append(f'{target}_LIBTOOLFLAGS = --tag=CC')

    if not additions:
        continue

    if not text.endswith('\n'):
        text += '\n'
    text += (
        '\n# libtool 2.5+ cannot infer the tag for .m compiles; force CC.\n'
        + '\n'.join(additions) + '\n'
    )
    mf.write_text(text)
    patched += 1
    print(f'  patched: {mf.relative_to(vlc_root)} ({len(additions)} target(s))')

print(f'Patched {patched} Makefile.am file(s) for OBJC libtool tag')
PYEOF

    # Force ./bootstrap to regenerate configure/Makefile.in so the new
    # per-target LIBTOOLFLAGS gets picked up. Also wipe per-platform build
    # dirs so their stale generated Makefiles are thrown away.
    rm -f "${VLC_SRC}/configure"
    rm -rf "${VLC_SRC}"/build-iphoneos-* \
           "${VLC_SRC}"/build-iphonesimulator-* \
           "${VLC_SRC}"/build-appletvos-* \
           "${VLC_SRC}"/build-appletvsimulator-* \
           "${VLC_SRC}"/build-macosx-* \
           "${VLC_SRC}"/build-maccatalyst-*

    info "Makefile.am files patched; configure + platform build dirs cleared"
}

patch_vlc_objc_libtool

# --- Step 1f: Disable Rust-based contribs ---
# VLC contribs pin cargo-c 0.9.29, which transitively pulls time 0.3.31 — a
# crate that no longer compiles on recent Rust (type inference for Box<_>).
# The only Rust contrib we'd get on Apple is rav1e (AV1 *encoder*); we already
# have dav1d for AV1 *decoding*, which is what matters for playback. iOS and
# tvOS already skip Rust (Tier 3 targets); this unifies macOS + Catalyst.
patch_vlc_disable_rust() {
    local MAIN_RUST_MAK="${VLC_SRC}/contrib/src/main-rust.mak"

    if grep -q 'SWIFTVLC_DISABLE_RUST' "$MAIN_RUST_MAK"; then
        info "VLC Rust contribs already disabled"
        return 0
    fi

    info "Disabling VLC Rust-based contribs..."

    python3 - "$MAIN_RUST_MAK" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
content = content.replace(
    'BUILD_RUST="1"',
    '# SWIFTVLC_DISABLE_RUST: cargo-c 0.9.29 fails on recent Rust; rav1e is\n'
    '# an encoder (dav1d handles AV1 decoding). Never set BUILD_RUST.\n'
    '# BUILD_RUST="1"'
)
with open(path, 'w') as f:
    f.write(content)
PYEOF

    info "VLC contrib/src/main-rust.mak patched to skip Rust contribs"
}

patch_vlc_disable_rust

# --- Step 2: Build tools ---
info "Building VLC build tools..."
export PATH="${VLC_SRC}/extras/tools/build/bin:$PATH"
cd "${VLC_SRC}/extras/tools"
./bootstrap
make ${MAKEFLAGS}
cd "${BUILD_DIR}"

# --- Step 3: Compile libVLC per platform/arch ---
#
# Force autoconf to treat Linux-only syscalls as unavailable. iOS Simulator
# SDK 26+ exports dup3/pipe2 from libSystem (so autoconf's link test says
# "yes"), but the iOS headers don't declare them — leading to
# "use of undeclared identifier 'dup3'" during src/posix/filesystem.c.
# Device builds correctly detect "no"; simulator (and newer Apple SDKs
# generally) get confused. VLC's code has proper #else fallbacks.
export ac_cv_func_dup3=no
export ac_cv_func_pipe2=no

compile_libvlc() {
    local ARCH="$1"
    local PLATFORM="$2"
    local ACTUAL_ARCH
    ACTUAL_ARCH=$(get_actual_arch "$ARCH")

    local SDK_VERSION
    SDK_VERSION=$(xcrun --sdk "${PLATFORM}" --show-sdk-version)

    info "Compiling libVLC for ${ACTUAL_ARCH} (${PLATFORM}, SDK ${SDK_VERSION})..."
    local platform_start=$(date +%s)

    # Use the normalized arch name for the build directory
    # This matches what VLC's build.sh creates internally
    local BUILDDIR="${VLC_SRC}/build-${PLATFORM}-${ACTUAL_ARCH}"
    mkdir -p "${BUILDDIR}"
    cd "${BUILDDIR}"

    "${VLC_SRC}/extras/package/apple/build.sh" \
        --arch="${ARCH}" \
        --sdk="${PLATFORM}${SDK_VERSION}" \
        ${MAKEFLAGS}

    cd "${BUILD_DIR}"

    local platform_end=$(date +%s)
    local platform_secs=$((platform_end - platform_start))
    local platform_mins=$((platform_secs / 60))
    info "Finished ${ACTUAL_ARCH} (${PLATFORM}) in ${platform_mins}m$((platform_secs % 60))s"
}

# Compile libVLC for Mac Catalyst.
# Uses the macOS SDK with --catalyst flag to set the macabi target triple.
compile_libvlc_catalyst() {
    local ARCH="$1"
    local ACTUAL_ARCH
    ACTUAL_ARCH=$(get_actual_arch "$ARCH")

    local SDK_VERSION
    SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)

    info "Compiling libVLC for ${ACTUAL_ARCH} (Mac Catalyst, macOS SDK ${SDK_VERSION})..."
    local platform_start=$(date +%s)

    # Use a separate build directory to avoid colliding with native macOS builds
    local BUILDDIR="${VLC_SRC}/build-maccatalyst-${ACTUAL_ARCH}"
    mkdir -p "${BUILDDIR}"
    cd "${BUILDDIR}"

    "${VLC_SRC}/extras/package/apple/build.sh" \
        --arch="${ARCH}" \
        --sdk="macosx${SDK_VERSION}" \
        --catalyst \
        ${MAKEFLAGS}

    cd "${BUILD_DIR}"

    local platform_end=$(date +%s)
    local platform_secs=$((platform_end - platform_start))
    local platform_mins=$((platform_secs / 60))
    info "Finished ${ACTUAL_ARCH} (Mac Catalyst) in ${platform_mins}m$((platform_secs % 60))s"
}

XCFRAMEWORK_ARGS=()

if [ "$BUILD_IOS" = "yes" ]; then
    # iOS device (arm64)
    compile_libvlc aarch64 iphoneos

    # iOS simulator (arm64 + x86_64)
    compile_libvlc aarch64 iphonesimulator
    compile_libvlc x86_64 iphonesimulator

    # Create fat library for simulator
    info "Creating fat library for iOS simulator..."
    mkdir -p "${BUILD_DIR}/libs/ios-simulator"
    lipo \
        "${VLC_SRC}/build-iphonesimulator-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-iphonesimulator-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/ios-simulator/libvlc.a"

    mkdir -p "${BUILD_DIR}/libs/ios-device"
    cp "${VLC_SRC}/build-iphoneos-arm64/static-lib/libvlc-full-static.a" \
       "${BUILD_DIR}/libs/ios-device/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/ios-device/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/ios-simulator/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

if [ "$BUILD_TVOS" = "yes" ]; then
    compile_libvlc aarch64 appletvos
    compile_libvlc aarch64 appletvsimulator
    compile_libvlc x86_64 appletvsimulator

    mkdir -p "${BUILD_DIR}/libs/tvos-simulator"
    lipo \
        "${VLC_SRC}/build-appletvsimulator-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-appletvsimulator-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/tvos-simulator/libvlc.a"

    mkdir -p "${BUILD_DIR}/libs/tvos-device"
    cp "${VLC_SRC}/build-appletvos-arm64/static-lib/libvlc-full-static.a" \
       "${BUILD_DIR}/libs/tvos-device/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/tvos-device/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/tvos-simulator/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

if [ "$BUILD_MACOS" = "yes" ]; then
    compile_libvlc aarch64 macosx
    compile_libvlc x86_64 macosx

    mkdir -p "${BUILD_DIR}/libs/macos"
    lipo \
        "${VLC_SRC}/build-macosx-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-macosx-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/macos/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/macos/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

if [ "$BUILD_CATALYST" = "yes" ]; then
    # Mac Catalyst (arm64 + x86_64)
    compile_libvlc_catalyst aarch64
    compile_libvlc_catalyst x86_64

    # Create fat library for Catalyst
    info "Creating fat library for Mac Catalyst..."
    mkdir -p "${BUILD_DIR}/libs/maccatalyst"
    lipo \
        "${VLC_SRC}/build-maccatalyst-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-maccatalyst-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/maccatalyst/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/maccatalyst/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

# --- Step 4: Create XCFramework ---
if [ ${#XCFRAMEWORK_ARGS[@]} -eq 0 ]; then
    error "No platforms were built. Use --macos, --ios-only, --tvos-only, --catalyst-only, --tvos, --macos, --catalyst, or --all"
fi

info "Creating libvlc.xcframework..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/libvlc.xcframework"

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "${OUTPUT_DIR}/libvlc.xcframework"

# Fix duplicate symbols (json_parse_error/json_read) in the static library.
# Two VLC plugins (ytdl, chromecast) each compile their own copy. The Apple
# linker in Xcode 16+ treats these as errors on some platforms (Mac Catalyst).
info "Fixing duplicate symbols in static libraries..."
"${SCRIPT_DIR}/fix-duplicate-symbols.sh" "${OUTPUT_DIR}/libvlc.xcframework"

# Remove the CLibVLC module.modulemap from xcframework headers to avoid
# "redefinition of module" errors when building with xcodebuild. The CLibVLC
# SPM target provides its own module map; the xcframework only needs the raw
# VLC C headers.
find "${OUTPUT_DIR}/libvlc.xcframework" -name "module.modulemap" -delete
find "${OUTPUT_DIR}/libvlc.xcframework" -name "CLibVLC.h" -delete

info "Created: ${OUTPUT_DIR}/libvlc.xcframework"

# --- Step 5: Verify ---
#
# Fail the build if any object file in the xcframework has an LC_BUILD_VERSION
# with `minos` exceeding the slice's expected deployment target. A contrib
# that slips the host-SDK default into its objects (see the gsm/CPPFLAGS
# fix above) would otherwise ship silently and trip the Apple linker with
# "built for newer 'X' version (Y) than being linked (Z)" warnings in every
# consumer project. Running this check at build time catches regressions
# here instead of in user feedback.
verify_deployment_targets() {
    info "Verifying deployment-target minimums in xcframework..."

    # slice_dir:expected_min_version — keep in sync with the SWIFTVLC_MIN_*
    # values above and the xcframework slice naming xcodebuild emits.
    local slices=(
        "ios-arm64:${SWIFTVLC_MIN_IOS}"
        "ios-arm64_x86_64-simulator:${SWIFTVLC_MIN_IOS}"
        "tvos-arm64:${SWIFTVLC_MIN_TVOS}"
        "tvos-arm64_x86_64-simulator:${SWIFTVLC_MIN_TVOS}"
        "macos-arm64_x86_64:${SWIFTVLC_MIN_MACOS}"
        "ios-arm64_x86_64-maccatalyst:${SWIFTVLC_MIN_CATALYST}"
    )

    local had_failure=0
    local slice_spec slice expected lib max_minos highest
    for slice_spec in "${slices[@]}"; do
        slice="${slice_spec%%:*}"
        expected="${slice_spec#*:}"
        lib="${OUTPUT_DIR}/libvlc.xcframework/${slice}/libvlc.a"
        [ -f "$lib" ] || continue

        # The highest LC_BUILD_VERSION minos across all objects in the archive.
        # LC_VERSION_MIN_IPHONEOS (legacy) is not inspected: ld prefers
        # LC_BUILD_VERSION when present and that's what produces the warning.
        max_minos=$(otool -l "$lib" 2>/dev/null \
            | awk '/^[[:space:]]*cmd LC_BUILD_VERSION/{flag=1; next} flag && /^[[:space:]]*minos /{print $2; flag=0}' \
            | sort -V | tail -1)

        if [ -z "$max_minos" ]; then
            warn "  ${slice}: no LC_BUILD_VERSION found (skipping)"
            continue
        fi

        # Pick the higher of (max_minos, expected); if it's max_minos, fail.
        highest=$(printf '%s\n%s\n' "$max_minos" "$expected" | sort -V | tail -1)
        if [ "$highest" = "$expected" ]; then
            info "  ${slice}: minos=${max_minos} <= deployment=${expected}"
        else
            warn "  ${slice}: minos=${max_minos} > deployment=${expected}"
            warn "    A contrib compiled with the host-SDK default instead of"
            warn "    SWIFTVLC_MIN_* — consumers will see ld warnings like"
            warn "    'built for newer X-version than being linked'."
            had_failure=1
        fi
    done

    if [ "$had_failure" -eq 1 ]; then
        error "Deployment-target verification failed (see warnings above)."
    fi
}

verify_deployment_targets

echo ""
info "Build complete!"
echo "  XCFramework: ${OUTPUT_DIR}/libvlc.xcframework"
echo "  Architectures:"
find "${OUTPUT_DIR}/libvlc.xcframework" -name "*.a" -exec lipo -info {} \;

local_end=$(date +%s)
local_total=$((local_end - BUILD_START_TIME))
local_mins=$((local_total / 60))
echo ""
echo "  Total time: ${local_mins}m$((local_total % 60))s"
echo ""
echo "To use: run 'swift build' in the SwiftVLC directory"
