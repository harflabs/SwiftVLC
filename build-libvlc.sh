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
BUILD_DIR="${SCRIPT_DIR}/.build-libvlc"
OUTPUT_DIR="${SCRIPT_DIR}/Vendor"
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
check_prerequisites() {
    local missing=()

    for cmd in autoconf automake libtool python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ! xcode-select -p >/dev/null 2>&1; then
        echo "${COLOR_RED}Error: Xcode command line tools not installed.${COLOR_RESET}" >&2
        echo "  Install with: xcode-select --install" >&2
        exit 1
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "${COLOR_RED}Error: Missing required tools: ${missing[*]}${COLOR_RESET}" >&2
        echo "" >&2
        echo "  Install with:" >&2
        echo "    brew install ${missing[*]}" >&2
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
    f.write('export VLC_DEPLOYMENT_TARGET_CATALYST="16.0"\n')

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

# 6. Add --target to CPPFLAGS in set_host_envvars() so packages that
#    override CFLAGS (like gsm) still get the macabi target via CPPFLAGS
content = content.replace(
    '    export CPPFLAGS="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
    '\n'
    '    export CFLAGS="$clike_flags"',
    '    export CPPFLAGS="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
    '    if [ "${VLC_BUILD_CATALYST:-0}" -gt "0" ]; then\n'
    '        CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG $CPPFLAGS"\n'
    '    fi\n'
    '\n'
    '    export CFLAGS="$clike_flags"'
)

# 7. Add --target to vlc_cppflags in write_config_mak() for contribs
content = content.replace(
    '    local vlc_cppflags="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
    '    local vlc_cflags="$clike_flags"',
    '    local vlc_cppflags="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
    '    if [ "${VLC_BUILD_CATALYST:-0}" -gt "0" ]; then\n'
    '        vlc_cppflags="$VLC_DEPLOYMENT_TARGET_CFLAG $vlc_cppflags"\n'
    '    fi\n'
    '    local vlc_cflags="$clike_flags"'
)

# 8. Add Catalyst-specific VLC configure options (disable GLES2/EGL
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

# 8b. Add Catalyst-specific module removal list. Modules wrapped in
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

# 9. Patch gl_common.h to treat Catalyst like macOS for OpenGL includes.
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

# 10. Patch interop_cvpx.m: On Catalyst, TARGET_OS_IPHONE=1 but OpenGLES
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

# 11. Patch VLCCVOpenGLProvider.m: both CVOpenGLES (iOS) and CVOpenGL (macOS)
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

# 12. Patch VLCOpenGLES2VideoView.m: entire file is EAGL/OpenGLES iOS view.
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

# 13. Patch ci_filters.m: uses #if !TARGET_OS_IPHONE for CGL vs EAGL.
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

# 14. Patch decoder.c (videotoolbox): kCVPixelBufferOpenGLESCompatibilityKey
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

# 15. Patch VLCSampleBufferDisplay.m: same kCVPixelBufferOpenGLESCompatibilityKey
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
    info "VLC source already cloned, resetting to ${VLC_HASH}..."
    cd vlc
    git fetch origin "$VLC_HASH"
    git reset --hard "${VLC_HASH}"
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

# --- Step 2: Build tools ---
info "Building VLC build tools..."
export PATH="${VLC_SRC}/extras/tools/build/bin:$PATH"
cd "${VLC_SRC}/extras/tools"
./bootstrap
make ${MAKEFLAGS}
cd "${BUILD_DIR}"

# --- Step 3: Compile libVLC per platform/arch ---
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

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/ios-device/libvlc.a" -headers "${SCRIPT_DIR}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/ios-simulator/libvlc.a" -headers "${SCRIPT_DIR}/Sources/CLibVLC/include")
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

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/tvos-device/libvlc.a" -headers "${SCRIPT_DIR}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/tvos-simulator/libvlc.a" -headers "${SCRIPT_DIR}/Sources/CLibVLC/include")
fi

if [ "$BUILD_MACOS" = "yes" ]; then
    compile_libvlc aarch64 macosx
    compile_libvlc x86_64 macosx

    mkdir -p "${BUILD_DIR}/libs/macos"
    lipo \
        "${VLC_SRC}/build-macosx-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-macosx-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/macos/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/macos/libvlc.a" -headers "${SCRIPT_DIR}/Sources/CLibVLC/include")
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

    XCFRAMEWORK_ARGS+=(-library "${BUILD_DIR}/libs/maccatalyst/libvlc.a" -headers "${SCRIPT_DIR}/Sources/CLibVLC/include")
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

# Remove the CLibVLC module.modulemap from xcframework headers to avoid
# "redefinition of module" errors when building with xcodebuild. The CLibVLC
# SPM target provides its own module map; the xcframework only needs the raw
# VLC C headers.
find "${OUTPUT_DIR}/libvlc.xcframework" -name "module.modulemap" -delete
find "${OUTPUT_DIR}/libvlc.xcframework" -name "CLibVLC.h" -delete

info "Created: ${OUTPUT_DIR}/libvlc.xcframework"

# --- Step 5: Verify ---
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
