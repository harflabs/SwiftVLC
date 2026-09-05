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
#   ./build-libvlc.sh --all        # Build for iOS, tvOS, visionOS, macOS, Catalyst
#   ./build-libvlc.sh --ios-only   # iOS device + simulator only
#   ./build-libvlc.sh --macos-only # macOS only (fastest for dev)
#   ./build-libvlc.sh --catalyst   # Add Mac Catalyst (arm64 + x86_64)
#   ./build-libvlc.sh --clean      # Remove build directory
#   ./build-libvlc.sh --build-root=/absolute/path --clean-build --all
#   ./build-libvlc.sh --build-root=/absolute/path # Canonical external work root
#   ./build-libvlc.sh --hash=abc   # Pin to a specific VLC commit

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
INVOCATION_DIRECTORY="$(/bin/pwd -P)"
# Keep the lock-owning parent shell inside the exact scripts directory it
# resolved. This gives checkout-local cleanup the same stable top-level anchor
# as an external --build-root: renaming or replacing the checkout pathname
# cannot redirect a later helper open into a different marker-bearing tree.
cd "${SCRIPT_DIR}"
DEFAULT_BUILD_DIR="${SCRIPT_DIR}/.build-libvlc"
BUILD_ROOT="."
BUILD_ROOT_HELPER="."
BUILD_ROOT_DISPLAY="${SCRIPT_DIR}"
BUILD_DIR=".build-libvlc"
BUILD_DIR_DISPLAY="${DEFAULT_BUILD_DIR}"
EXTERNAL_BUILD_ROOT=no
BUILD_ROOT_OVERRIDE=""
BUILD_ROOT_OVERRIDE_SET=no
BUILD_LOCK_DIR=""
BUILD_LOCK_DISPLAY=""
BUILD_LOCK_PARENT_FD=8
BUILD_LOCK_PARENT_FD_OPEN=no
BUILD_LOCK_HELD=no
OUTPUT_LOCK_DIR=""
OUTPUT_LOCK_NAME=""
OUTPUT_LOCK_DISPLAY=""
OUTPUT_LOCK_PARENT_FD=9
OUTPUT_LOCK_PARENT_FD_OPEN=no
OUTPUT_LOCK_HELD=no
LOCK_TOKEN_NAME=".swiftvlc-lock-generation-v1"
BUILD_LOCK_TOKEN_CONTENT=""
OUTPUT_LOCK_TOKEN_CONTENT=""
OUTPUT_BINDING_HELD=no
BUILD_DIRECTORY_MARKER=".swiftvlc-managed-libvlc-build-v1"
BUILD_DIRECTORY_MARKER_CONTENT="SwiftVLC managed libVLC build directory v1"
BUILD_DIRECTORY_CHILD=".build-libvlc"
STAGED_OUTPUT_MARKER=".swiftvlc-managed-native-output-v1"
STAGED_OUTPUT_MARKER_CONTENT="SwiftVLC managed native output directory v1"
BUILD_QUARANTINE_NAME=""
BUILD_QUARANTINE_DIR=""
BUILD_QUARANTINE_PAYLOAD=""
BUILD_BINDING_NAME=""
BUILD_BINDING_CONTENT=""
VLC_SOURCE_BINDING_NAME=""
VLC_SOURCE_BINDING_CONTENT=""
OUTPUT_BINDING_NAME=""
OUTPUT_BINDING_CONTENT=""
STAGED_OUTPUT_BINDING_NAME=""
STAGED_OUTPUT_BINDING_CONTENT=""
PUBLISHED_ARTIFACT_REMOVAL_BINDING_NAME=".swiftvlc-managed-artifact-removal-v1"
PUBLISHED_ARTIFACT_REMOVAL_BINDING_CONTENT=""
PUBLISHING_BINDING_NAME=".swiftvlc-managed-publication-binding-v1"
PUBLISHING_BINDING_CONTENT=""
OUTPUT_DIR="${REPO_ROOT}/Vendor"
VLC_REPO="https://code.videolan.org/videolan/vlc.git"
VLC_BRANCH="master"
# Pin to a known-good commit for reproducible builds. This intentionally does
# not track VLCKit's moving pin: newer libVLC revisions changed libvlc_time_t
# from milliseconds to microseconds and require a coordinated wrapper migration.
# Update this hash only as part of an audited libVLC API upgrade.
VLC_HASH="c833c4be0"

# Directory containing source patches applied to the VLC checkout before
# configure. Defaults to the in-repo patch set (chromecast hardening) and can
# be overridden or cleared with --patches-dir=DIR.
PATCHES_DIR="${REPO_ROOT}/scripts/patches"

# The manifest that decides which patches apply and in what order lives beside
# them, and is verified by scripts/verify-patch-manifest.sh — which owns its
# filename, so nothing here needs to know it.

BUILD_IOS=yes
BUILD_TVOS=no
BUILD_VISIONOS=no
BUILD_MACOS=no
BUILD_CATALYST=no

# libVLC run-time assertions are OFF by default. VLC defaults to assertions
# enabled, but a shipped media library must not abort() the host process on
# malformed input: many "should not happen" branches in libVLC (e.g.
# hxxx_helper_process_block, which crashed on certain FLV/H.264 files — see
# issue #30) sit directly above a graceful fallback that only runs once the
# assert is compiled out via NDEBUG. Disabling debug matches how VLCKit and
# official VLC release builds ship. Developers debugging codec internals can
# restore the asserts with --with-asserts.
WITH_ASSERTS=no
CLEAN_BUILD=no
CLEAN_ONLY=no

# Keep these deployment targets in sync with Package.swift.
SWIFTVLC_MIN_IOS="18.0"
SWIFTVLC_MIN_TVOS="18.0"
SWIFTVLC_MIN_VISIONOS="2.0"
SWIFTVLC_MIN_MACOS="15.0"
SWIFTVLC_MIN_CATALYST="18.0"

BUILD_START_TIME=$(date +%s)
BUILD_INVOCATION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
BUILD_QUARANTINE_NAME=".build-libvlc.removing-${BUILD_INVOCATION_ID}"
BUILD_QUARANTINE_DIR="${SCRIPT_DIR}/${BUILD_QUARANTINE_NAME}"
BUILD_QUARANTINE_PAYLOAD="${BUILD_QUARANTINE_DIR}/payload"
BUILD_BINDING_NAME=".swiftvlc-managed-build-binding-v1"
BUILD_BINDING_CONTENT="SwiftVLC managed build binding ${BUILD_INVOCATION_ID}"
VLC_SOURCE_BINDING_NAME=".swiftvlc-managed-vlc-binding-v1"
VLC_SOURCE_BINDING_CONTENT="SwiftVLC managed VLC binding ${BUILD_INVOCATION_ID}"
OUTPUT_BINDING_NAME=".swiftvlc-managed-output-binding-v1"
OUTPUT_BINDING_CONTENT="SwiftVLC managed output binding ${BUILD_INVOCATION_ID}"
STAGED_OUTPUT_BINDING_NAME=".swiftvlc-managed-native-output-binding-v1"
STAGED_OUTPUT_BINDING_CONTENT="SwiftVLC managed native output binding ${BUILD_INVOCATION_ID}"
PUBLISHED_ARTIFACT_REMOVAL_BINDING_CONTENT="SwiftVLC managed artifact removal ${BUILD_INVOCATION_ID}"
PUBLISHING_BINDING_CONTENT="SwiftVLC managed publication binding ${BUILD_INVOCATION_ID}"
BUILD_LOCK_TOKEN_CONTENT="SwiftVLC external build-root lock ${BUILD_INVOCATION_ID}"
OUTPUT_LOCK_TOKEN_CONTENT="SwiftVLC checkout output lock ${BUILD_INVOCATION_ID}"

if [ -z "$MAKEFLAGS" ]; then
    MAKEFLAGS="-j$(sysctl -n machdep.cpu.core_count || nproc)"
fi

# --- Terminal color support ---
# Guard tput calls for non-terminal and colorless contexts. `TERM=dumb`
# reports `tput colors` as -1 with a successful exit status, while `setaf`
# still fails; checking the numeric capability prevents the ERR trap from
# masking the real build before logging has even initialized.
TPUT_COLORS=0
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    TPUT_COLORS=$(tput colors 2>/dev/null || echo 0)
fi
if [ "${TPUT_COLORS}" -ge 8 ] 2>/dev/null; then
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

# A release reproducibility proof uses two different SwiftVLC checkouts, but
# VLC and several contribs retain their absolute source/configure paths in live
# string data. Giving both sequential builds the same external working root
# makes that otherwise-hidden input explicit and stable. BUILD_DIR is always a
# fixed child of the user-selected root so cleanup never targets the root
# itself. Existing children must carry our ownership marker before deletion.
configure_external_build_root() {
    local requested_root="$1"
    local canonical_root

    if [ -z "${requested_root}" ]; then
        error "--build-root requires an absolute directory path."
    fi
    case "${requested_root}" in
        /*) ;;
        *) error "--build-root must be an absolute directory path: ${requested_root}" ;;
    esac
    while [ "${requested_root}" != "/" ] &&
          [ "${requested_root%/}" != "${requested_root}" ]; do
        requested_root="${requested_root%/}"
    done
    if [ ! -d "${requested_root}" ]; then
        error "External build root does not exist: ${requested_root}"
    fi
    # Stay inside the directory we canonicalize. The shell's live CWD anchors
    # this exact inode even if a non-cooperating process later renames or
    # replaces the absolute root pathname.
    cd "${requested_root}"
    canonical_root=$(/bin/pwd -P)
    if [ "${canonical_root}" != "${requested_root}" ]; then
        error "--build-root must use its canonical physical path: ${canonical_root}"
    fi
    if [ "${canonical_root}" = "/" ]; then
        error "Refusing to use the filesystem root as --build-root."
    fi
    case "${canonical_root}/" in
        "${REPO_ROOT}/"*)
            error "--build-root must be outside the SwiftVLC checkout so separate checkouts share one path."
            ;;
    esac
    case "${REPO_ROOT}/" in
        "${canonical_root}/swiftvlc-libvlc-build/"*)
            error "Refusing an external build directory that contains the SwiftVLC checkout."
            ;;
    esac

    BUILD_DIRECTORY_CHILD="swiftvlc-libvlc-build"
    BUILD_QUARANTINE_NAME=".swiftvlc-libvlc-build.removing-${BUILD_INVOCATION_ID}"
    BUILD_ROOT="."
    BUILD_ROOT_HELPER="."
    BUILD_ROOT_DISPLAY="${canonical_root}"
    BUILD_DIR="${BUILD_DIRECTORY_CHILD}"
    BUILD_DIR_DISPLAY="${canonical_root}/${BUILD_DIRECTORY_CHILD}"
    BUILD_LOCK_DIR=".swiftvlc-libvlc-build.lock"
    BUILD_LOCK_DISPLAY="${canonical_root}/.swiftvlc-libvlc-build.lock"
    BUILD_QUARANTINE_DIR="${canonical_root}/${BUILD_QUARANTINE_NAME}"
    BUILD_QUARANTINE_PAYLOAD="${BUILD_QUARANTINE_DIR}/payload"
    EXTERNAL_BUILD_ROOT=yes
}

managed_build_directory_helper() {
    local operation="$1"
    shift
    PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" \
        "${operation}" \
        --root "${BUILD_ROOT_HELPER}" \
        --child "${BUILD_DIRECTORY_CHILD}" \
        --marker-name "${BUILD_DIRECTORY_MARKER}" \
        --marker-content "${BUILD_DIRECTORY_MARKER_CONTENT}" \
        "$@"
}

bind_directory_for_handoff() {
    local root="$1"
    local child="$2"
    local binding_name="$3"
    local binding_content="$4"
    shift 4
    PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" \
        bind \
        --root "${root}" \
        --child "${child}" \
        --marker-name "${BUILD_DIRECTORY_MARKER}" \
        --marker-content "${BUILD_DIRECTORY_MARKER_CONTENT}" \
        --binding-name "${binding_name}" \
        --binding-content "${binding_content}" \
        "$@"
}

verify_directory_binding() {
    local binding_name="$1"
    local binding_content="$2"
    local description="$3"
    if [ -L "${binding_name}" ] || \
       [ ! -f "${binding_name}" ] || \
       ! printf '%s\n' "${binding_content}" | cmp -s - "${binding_name}"; then
        error "${description} changed before it could be anchored."
    fi
}

retire_directory_binding() {
    local binding_name="$1"
    local binding_content="$2"
    local description="$3"
    verify_directory_binding \
        "${binding_name}" "${binding_content}" "${description}"
    rm -f -- "${binding_name}"
    if [ -e "${binding_name}" ] || [ -L "${binding_name}" ]; then
        error "Could not retire ${description} binding: ${binding_name}"
    fi
}

release_output_binding() {
    if [ "${OUTPUT_BINDING_HELD}" != yes ]; then
        return 0
    fi
    # Enter the current public Vendor path but remove a file only when it still
    # carries this invocation's exact continuity token. If Vendor or an
    # ancestor was replaced, leave both directories untouched for inspection.
    (
    if ! cd "${REPO_ROOT}/Vendor" 2>/dev/null; then
        return 0
    fi
    if [ ! -e "${OUTPUT_BINDING_NAME}" ] && \
       [ ! -L "${OUTPUT_BINDING_NAME}" ]; then
        return 0
    fi
    if [ -L "${OUTPUT_BINDING_NAME}" ] || \
       [ ! -f "${OUTPUT_BINDING_NAME}" ] || \
       ! printf '%s\n' "${OUTPUT_BINDING_CONTENT}" | \
         cmp -s - "${OUTPUT_BINDING_NAME}"; then
        warn "Vendor output binding changed; leaving it untouched: ${REPO_ROOT}/Vendor/${OUTPUT_BINDING_NAME}"
        return 0
    fi
    if ! rm -f -- "${OUTPUT_BINDING_NAME}"; then
        warn "Could not remove Vendor output binding: ${REPO_ROOT}/Vendor/${OUTPUT_BINDING_NAME}"
    fi
    ) || true
    OUTPUT_BINDING_HELD=no
    return 0
}

verify_managed_build_directory() {
    if [ "${EXTERNAL_BUILD_ROOT}" != yes ]; then
        return
    fi
    if [ -L "${BUILD_DIR}" ]; then
        error "Refusing symlinked managed build directory: ${BUILD_DIR_DISPLAY}"
    fi
    if [ ! -e "${BUILD_DIR}" ]; then
        return
    fi
    if [ ! -d "${BUILD_DIR}" ]; then
        error "Managed build path is not a directory: ${BUILD_DIR_DISPLAY}"
    fi
    if [ -L "${BUILD_DIR}/${BUILD_DIRECTORY_MARKER}" ] ||
       [ ! -f "${BUILD_DIR}/${BUILD_DIRECTORY_MARKER}" ]; then
        error "Refusing unowned external build directory: ${BUILD_DIR_DISPLAY}"
    fi
    if ! printf '%s\n' "${BUILD_DIRECTORY_MARKER_CONTENT}" | \
         cmp -s - "${BUILD_DIR}/${BUILD_DIRECTORY_MARKER}"; then
        error "Refusing unowned external build directory: ${BUILD_DIR_DISPLAY}"
    fi
}

release_build_root_lock() {
    if [ "${BUILD_LOCK_HELD}" != yes ]; then
        return 0
    fi
    # Release only the exact generation acquired by this invocation. The
    # helper retains and validates both the anchored parent descriptor and the
    # opened lock directory, so path replacement cannot retire a successor.
    if ! PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" lock-release \
        --root-fd "${BUILD_LOCK_PARENT_FD}" \
        --child "${BUILD_LOCK_DIR}" \
        --token-name "${LOCK_TOKEN_NAME}" \
        --token-content "${BUILD_LOCK_TOKEN_CONTENT}"; then
        warn "Could not remove external build-root lock: ${BUILD_LOCK_DISPLAY}"
    fi
    BUILD_LOCK_HELD=no
    return 0
}

close_build_lock_parent() {
    if [ "${BUILD_LOCK_PARENT_FD_OPEN}" != yes ]; then
        return 0
    fi
    exec 8<&-
    BUILD_LOCK_PARENT_FD_OPEN=no
    return 0
}

acquire_build_root_lock() {
    if [ "${EXTERNAL_BUILD_ROOT}" != yes ]; then
        return
    fi
    if ! exec 8<.; then
        error "Could not anchor external build-root lock parent: ${BUILD_ROOT_DISPLAY}"
    fi
    BUILD_LOCK_PARENT_FD_OPEN=yes
    if ! PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" lock-acquire \
        --root-fd "${BUILD_LOCK_PARENT_FD}" \
        --child "${BUILD_LOCK_DIR}" \
        --token-name "${LOCK_TOKEN_NAME}" \
        --token-content "${BUILD_LOCK_TOKEN_CONTENT}"; then
        error "External build root is locked or has preserved lock state; verify no build is active and inspect this exact managed lock: ${BUILD_LOCK_DISPLAY}"
    fi
    BUILD_LOCK_HELD=yes
}

reject_stale_managed_build_state() {
    local candidate
    local candidate_name
    local quarantine_pattern
    if [ "${EXTERNAL_BUILD_ROOT}" = yes ]; then
        quarantine_pattern=./.swiftvlc-libvlc-build.removing-\*
    else
        quarantine_pattern=./.build-libvlc.removing-\*
    fi
    (
    cd "${BUILD_ROOT_HELPER}"
    for candidate in \
        ${quarantine_pattern} \
        ./.swiftvlc-lock.initializing-* \
        ./.swiftvlc-managed-build.initializing-*; do
        if [ ! -e "${candidate}" ] && [ ! -L "${candidate}" ]; then
            continue
        fi
        candidate_name=${candidate#./}
        error "Found preserved managed-build state: ${BUILD_ROOT_DISPLAY}/${candidate_name}. Inspect and recover or remove this exact path before retrying; it is never deleted automatically."
    done
    )
    return 0
}

release_output_lock() {
    if [ "${OUTPUT_LOCK_HELD}" != yes ]; then
        return 0
    fi
    # Keep the Git lock-parent descriptor opened before an external build
    # re-anchors the shell elsewhere. Descriptor-relative removal cannot be
    # redirected into a replacement checkout or linked-worktree metadata path.
    if ! PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" lock-release \
        --root-fd "${OUTPUT_LOCK_PARENT_FD}" \
        --child "${OUTPUT_LOCK_NAME}" \
        --token-name "${LOCK_TOKEN_NAME}" \
        --token-content "${OUTPUT_LOCK_TOKEN_CONTENT}"; then
        warn "Could not remove checkout artifact lock: ${OUTPUT_LOCK_DISPLAY}"
    fi
    OUTPUT_LOCK_HELD=no
    return 0
}

close_output_lock_parent() {
    if [ "${OUTPUT_LOCK_PARENT_FD_OPEN}" != yes ]; then
        return 0
    fi
    exec 9<&-
    OUTPUT_LOCK_PARENT_FD_OPEN=no
    return 0
}

release_build_locks() {
    release_output_binding || true
    release_output_lock || true
    release_build_root_lock || true
    close_build_lock_parent || true
    close_output_lock_parent || true
    return 0
}

acquire_output_lock() {
    local raw_lock_path
    local lock_parent
    if [ "$(/bin/pwd -P)" != "${SCRIPT_DIR}" ]; then
        error "Checkout output lock must be anchored before leaving the scripts directory."
    fi
    raw_lock_path=$(git -C . rev-parse --git-path swiftvlc-libvlc-output.lock)
    case "${raw_lock_path}" in
        /*) ;;
        *) raw_lock_path="${SCRIPT_DIR}/${raw_lock_path}" ;;
    esac
    lock_parent=$(cd "$(dirname "${raw_lock_path}")" && /bin/pwd -P)
    OUTPUT_LOCK_NAME=$(basename "${raw_lock_path}")
    OUTPUT_LOCK_DISPLAY="${lock_parent}/${OUTPUT_LOCK_NAME}"
    OUTPUT_LOCK_DIR="${OUTPUT_LOCK_DISPLAY}"
    if ! exec 9<"${lock_parent}"; then
        error "Could not anchor checkout artifact-lock parent: ${lock_parent}"
    fi
    OUTPUT_LOCK_PARENT_FD_OPEN=yes
    if ! PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" lock-acquire \
        --root-fd "${OUTPUT_LOCK_PARENT_FD}" \
        --child "${OUTPUT_LOCK_NAME}" \
        --token-name "${LOCK_TOKEN_NAME}" \
        --token-content "${OUTPUT_LOCK_TOKEN_CONTENT}"; then
        error "This checkout already has a native build or cleanup in progress, or preserved lock state; verify no build is active and inspect this exact managed lock: ${OUTPUT_LOCK_DISPLAY}"
    fi
    OUTPUT_LOCK_HELD=yes
}

initialize_managed_build_directory() {
    if [ "${CLEAN_BUILD}" = yes ]; then
        if ! managed_build_directory_helper initialize --require-new \
            --binding-name "${BUILD_BINDING_NAME}" \
            --binding-content "${BUILD_BINDING_CONTENT}"; then
            error "Could not exclusively initialize a fresh managed build directory: ${BUILD_DIR_DISPLAY}"
        fi
    elif ! managed_build_directory_helper initialize \
        --binding-name "${BUILD_BINDING_NAME}" \
        --binding-content "${BUILD_BINDING_CONTENT}"; then
        error "Could not safely initialize managed build directory: ${BUILD_DIR_DISPLAY}"
    fi
}

verify_checkout_path_not_embedded() {
    if [ "${EXTERNAL_BUILD_ROOT}" != yes ]; then
        return
    fi
    # Open the already-anchored output CWD only for this command. The verifier
    # resolves and walks the XCFramework below FD 7 without re-entering a
    # replaceable external-root pathname.
    PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/verify-libvlc-build-paths.py" \
        --xcframework-parent-fd 7 \
        --xcframework-child "libvlc.xcframework" \
        --forbidden-path "${REPO_ROOT}" \
        7<.
}

trap release_build_locks EXIT

# --- Error trap for better failure reporting ---
# Install only after `error` and its formatting dependencies are defined so a
# startup failure cannot be replaced by `error: command not found`.
trap 'error "Build failed at line $LINENO (exit code $?)"' ERR

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
    # Contrib and per-SDK/architecture build products coexist until the
    # XCFramework is assembled. Count the actual compile_libvlc invocations,
    # including both simulator architectures, so an `--all` preflight reflects
    # the peak working set instead of the number of final XCFramework slices.
    local build_count=0
    if [ "$BUILD_IOS" = yes ]; then build_count=$((build_count + 3)); fi
    if [ "$BUILD_TVOS" = yes ]; then build_count=$((build_count + 3)); fi
    if [ "$BUILD_VISIONOS" = yes ]; then build_count=$((build_count + 3)); fi
    if [ "$BUILD_MACOS" = yes ]; then build_count=$((build_count + 2)); fi
    if [ "$BUILD_CATALYST" = yes ]; then build_count=$((build_count + 2)); fi

    local required_gb=$((20 + build_count * 6))
    if [ "$required_gb" -lt 40 ]; then
        required_gb=40
    fi
    local available_kb
    available_kb=$(df -k "$BUILD_ROOT" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [ "$available_gb" -lt "$required_gb" ]; then
        error "Insufficient disk space on the build volume: ${available_gb}GB available, ${required_gb}GB required for ${build_count} selected architecture builds."
    fi
}

# Finder, Spotlight, and filesystem metadata helpers can recreate dotfiles while
# a large external-volume tree is being removed. A single rm -rf can therefore
# leave a newly populated directory behind and report "Directory not empty".
# Clean builds must start from an absent tree, so retry the whole removal and
# fail closed if any writer keeps repopulating it.
remove_build_directory() {
    local cleanup_status

    # Verification and deletion cannot safely share the public pathname. The
    # helper opens and verifies the exact directory, atomically renames it
    # beneath a private quarantine, then keeps that original descriptor live
    # while walking and unlinking entries relative to directory FDs. Use this
    # for both external and legacy checkout-local roots; neither path gets a
    # recursive shell fallback.
    if managed_build_directory_helper clean \
        --quarantine "${BUILD_QUARANTINE_NAME}"; then
        cleanup_status=0
    else
        cleanup_status=$?
    fi
    if [ "${cleanup_status}" -eq 3 ]; then
        if [ -e "${BUILD_DIR}" ] || [ -L "${BUILD_DIR}" ]; then
            error "Managed build path appeared during cleanup and was left untouched: ${BUILD_DIR_DISPLAY}"
        fi
        return 0
    fi
    if [ "${cleanup_status}" -ne 0 ]; then
        error "Could not safely clean managed build directory; any detached data was preserved for inspection: ${BUILD_QUARANTINE_DIR}"
    fi
    if [ -e "${BUILD_DIR}" ] || [ -L "${BUILD_DIR}" ]; then
        error "Managed build path reappeared during cleanup and was left untouched: ${BUILD_DIR_DISPLAY}"
    fi
    return 0
}

# Resolve this before processing --clean/--clean-build: cleanup must never
# depend on option order. Reject duplicates rather than silently selecting one
# root and deleting another caller's managed directory.
for arg in "$@"; do
    case $arg in
        --build-root=*)
            if [ "${BUILD_ROOT_OVERRIDE_SET}" = yes ]; then
                error "--build-root may be specified only once."
            fi
            BUILD_ROOT_OVERRIDE="${arg#--build-root=}"
            BUILD_ROOT_OVERRIDE_SET=yes
            ;;
    esac
done

# --- Parse arguments ---
for arg in "$@"; do
    case $arg in
        --all)
            BUILD_IOS=yes
            BUILD_TVOS=yes
            BUILD_VISIONOS=yes
            BUILD_MACOS=yes
            BUILD_CATALYST=yes
            ;;
        --ios-only)
            BUILD_IOS=yes
            BUILD_TVOS=no
            BUILD_VISIONOS=no
            BUILD_MACOS=no
            BUILD_CATALYST=no
            ;;
        --tvos)
            BUILD_TVOS=yes
            ;;
        --visionos)
            BUILD_VISIONOS=yes
            ;;
        --macos)
            BUILD_MACOS=yes
            ;;
        --macos-only)
            BUILD_IOS=no
            BUILD_TVOS=no
            BUILD_VISIONOS=no
            BUILD_MACOS=yes
            BUILD_CATALYST=no
            ;;
        --tvos-only)
            BUILD_IOS=no
            BUILD_TVOS=yes
            BUILD_VISIONOS=no
            BUILD_MACOS=no
            BUILD_CATALYST=no
            ;;
        --visionos-only)
            BUILD_IOS=no
            BUILD_TVOS=no
            BUILD_VISIONOS=yes
            BUILD_MACOS=no
            BUILD_CATALYST=no
            ;;
        --catalyst)
            BUILD_CATALYST=yes
            ;;
        --catalyst-only)
            BUILD_IOS=no
            BUILD_TVOS=no
            BUILD_VISIONOS=no
            BUILD_MACOS=no
            BUILD_CATALYST=yes
            ;;
        --clean)
            CLEAN_ONLY=yes
            ;;
        --clean-build)
            CLEAN_BUILD=yes
            ;;
        --with-asserts)
            WITH_ASSERTS=yes
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
            case "${PATCHES_DIR}" in
                /*) ;;
                *) PATCHES_DIR="${INVOCATION_DIRECTORY}/${PATCHES_DIR}" ;;
            esac
            if [ ! -d "$PATCHES_DIR" ]; then
                echo "Error: Patches directory not found: ${PATCHES_DIR}" >&2
                exit 1
            fi
            ;;
        --build-root=*)
            # Resolved before this loop so --clean is safe regardless of
            # argument order.
            ;;
        --help)
            cat <<HELPEOF
Usage: $0 [OPTIONS]

Platform selection:
  --all              Build for iOS, tvOS, visionOS, macOS, and Mac Catalyst
  --ios-only         iOS device + simulator only (default)
  --macos-only       macOS only (fastest for development)
  --tvos-only        tvOS device + simulator only
  --visionos-only    visionOS device + simulator only
  --catalyst-only    Mac Catalyst only
  --tvos             Add tvOS to the build
  --visionos         Add visionOS to the build
  --macos            Add macOS to the build
  --catalyst         Add Mac Catalyst to the build

Build options:
  --clean            Remove the build directory and exit
  --clean-build      Remove the build directory, then build
  --build-root=DIR   Use DIR/swiftvlc-libvlc-build as the canonical external
                     working directory. DIR must already exist, be outside
                     this checkout, and be identical for both release builds.
  --hash=COMMIT      Pin to a specific VLC commit (default: ${VLC_HASH})
  --patches-dir=DIR  Directory containing .patch files to apply
  --with-asserts     Enable libVLC run-time assertions (debugging only; these
                     abort() on some malformed input — released builds omit
                     this so libVLC takes its graceful error paths instead)

Other:
  --help             Show this help message

Examples:
  $0                          # Build for iOS (default)
  $0 --macos-only             # Quick macOS build for development
  $0 --all                    # Full build for all platforms
  $0 --hash=abc123 --all      # Build all platforms from a specific commit
  $0 --build-root=/Volumes/Builds --clean-build --all
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

if [ "${CLEAN_ONLY}" = yes ] && [ "${CLEAN_BUILD}" = yes ]; then
    error "--clean and --clean-build cannot be used together."
fi
if [ "${CLEAN_BUILD}" = yes ] && [ "${BUILD_ROOT_OVERRIDE_SET}" != yes ]; then
    error "--clean-build requires a canonical external --build-root so release builds cannot depend on a checkout-local path."
fi

# Every native invocation that can delete its work tree or replace Vendor must
# own this checkout's artifact lock. Acquire it while the shell is still in its
# original scripts-directory CWD, and retain the Git lock-parent descriptor so
# linked-worktree or checkout path replacement cannot redirect its release.
acquire_output_lock

# Bind the original checkout's Vendor generation before an external build root
# changes the parent shell's CWD. Later absolute-path entry must present this
# exact invocation token; a renamed/replaced checkout therefore fails closed
# instead of minting authority in the replacement tree.
if [ "${CLEAN_ONLY}" != yes ]; then
    if ! (
        cd -P ..
        if [ "$(/bin/pwd -P)" != "${REPO_ROOT}" ]; then
            error "SwiftVLC checkout path changed before Vendor could be anchored."
        fi
        for preserved_checkout_state in \
            ./.swiftvlc-managed-build.initializing-*; do
            if [ -e "${preserved_checkout_state}" ] || \
               [ -L "${preserved_checkout_state}" ]; then
                error "Found preserved checkout publication state: ${preserved_checkout_state}. Inspect and recover or remove it before retrying."
            fi
        done
        if ! bind_directory_for_handoff \
            . Vendor \
            "${OUTPUT_BINDING_NAME}" "${OUTPUT_BINDING_CONTENT}" \
            --create; then
            error "Could not safely anchor the original checkout Vendor output directory."
        fi
    ); then
        error "Could not establish original checkout continuity for native output."
    fi
    OUTPUT_BINDING_HELD=yes
fi

# Only now may external mode re-anchor the parent at its canonical build root.
# The checkout output lock and Vendor token above remain tied to the original
# checkout while the build-root lock remains tied to this new live CWD.
if [ "${BUILD_ROOT_OVERRIDE_SET}" = yes ]; then
    configure_external_build_root "${BUILD_ROOT_OVERRIDE}"
    acquire_build_root_lock
    reject_stale_managed_build_state
    verify_managed_build_directory
    info "Canonical external build root: ${BUILD_ROOT_DISPLAY}"
    info "Managed native build directory: ${BUILD_DIR_DISPLAY}"
else
    reject_stale_managed_build_state
fi

if [ "${CLEAN_ONLY}" = yes ]; then
    echo "Removing build directory: ${BUILD_DIR_DISPLAY}"
    remove_build_directory
    echo "Done."
    exit 0
fi

# Record the exact SwiftVLC commit whose build logic and vendored headers are
# producing this artifact. A short or symbolic revision would allow a stale
# clean-build record to be paired with a later checkout after refs move.
SWIFTVLC_REVISION=$(git -C "${REPO_ROOT}" rev-parse --verify 'HEAD^{commit}')
if ! [[ "${SWIFTVLC_REVISION}" =~ ^[0-9a-f]{40}$ ]]; then
    error "Could not resolve SwiftVLC HEAD to a full lowercase commit ID."
fi
info "SwiftVLC source provenance: ${SWIFTVLC_REVISION}"

verify_clean_swiftvlc_checkout() {
    local current_revision
    local checkout_status
    current_revision=$(git -C "${REPO_ROOT}" rev-parse --verify 'HEAD^{commit}')
    if [ "${current_revision}" != "${SWIFTVLC_REVISION}" ]; then
        error "SwiftVLC HEAD changed during the clean native build."
    fi
    checkout_status=$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=all)
    if [ -n "${checkout_status}" ]; then
        error "A release-quality --clean-build requires a clean SwiftVLC checkout. Commit, ignore, or remove checkout changes first."
    fi
}

# Incremental developer builds may come from an in-progress checkout, but only
# --clean-build records can enter a reproducibility proof. Fail those builds
# before compilation rather than attributing dirty tracked or untracked inputs
# (including an untracked public header) to HEAD. Ignored build outputs do not
# appear in this check.
if [ "${CLEAN_BUILD}" = yes ]; then
    verify_clean_swiftvlc_checkout
    echo "Removing build directory: ${BUILD_DIR_DISPLAY}"
    remove_build_directory
    echo "Continuing with fresh build..."
fi

# --- Run startup checks ---
check_prerequisites
info "Verifying native validator asset manifest..."
if ! python3 "${SCRIPT_DIR}/verify-native-validator-assets.py"; then
    error "Native validator asset manifest verification failed."
fi
check_disk_space

# Any new native build invalidates the previous two-build evidence immediately.
# Re-enter the public Vendor path only after the early original-checkout bind:
# a checkout replacement cannot present this invocation's continuity token.
# Do this before source setup/compilation so an interrupted replacement cannot
# leave an older A record or proof looking current beside the prior artifact.
(
cd "${OUTPUT_DIR}"
verify_directory_binding \
    "${OUTPUT_BINDING_NAME}" "${OUTPUT_BINDING_CONTENT}" \
    "Checkout Vendor output directory"
for preserved_output_state in \
    ./.swiftvlc-native-output-publishing-* \
    ./.swiftvlc-published-artifact.removing-* \
    ./.swiftvlc-managed-build.initializing-* \
    "./libvlc.xcframework/${PUBLISHED_ARTIFACT_REMOVAL_BINDING_NAME}"; do
    if [ -e "${preserved_output_state}" ] || [ -L "${preserved_output_state}" ]; then
        error "Found preserved Vendor publication state: ${preserved_output_state}. Inspect and recover or remove it before retrying."
    fi
done
rm -f ./libvlc-provenance-a.json \
    ./libvlc-provenance.json \
    ./libvlc-reproducibility.json \
    ./libvlc-macho-metadata.json
)

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

# Keep the lock-owning parent shell anchored at the external root. The native
# body runs in a child shell whose CWD becomes the exact managed directory;
# its path and CWD changes therefore cannot redirect the parent's EXIT cleanup.
(
trap - EXIT
trap 'error "Native build body failed at line $LINENO (exit code $?)"' ERR

# --- Step 1: Clone VLC source ---
info "Setting up VLC source..."
initialize_managed_build_directory
# Enter the exact child initialized through a no-follow root descriptor, then
# require its one-use binding. This protects both external release roots and
# the legacy checkout-local developer root; neither path relies on a bare
# mkdir/marker check before native mutations begin.
cd "${BUILD_DIR}"
if [ -L "${BUILD_DIRECTORY_MARKER}" ] || \
   [ ! -f "${BUILD_DIRECTORY_MARKER}" ] || \
   ! printf '%s\n' "${BUILD_DIRECTORY_MARKER_CONTENT}" | \
     cmp -s - "${BUILD_DIRECTORY_MARKER}"; then
    error "Managed build directory changed before it could be anchored: ${BUILD_DIR_DISPLAY}"
fi
retire_directory_binding \
    "${BUILD_BINDING_NAME}" "${BUILD_BINDING_CONTENT}" \
    "Managed build directory"
BUILD_DIR="."

# A managed root authorizes its own files, but never a symlink or filesystem
# mounted beneath its `vlc` entry. The helper creates a one-use binding in the
# exact no-follow directory it opened; validating that binding after `cd`
# bridges the remaining pathname race. All subsequent source mutations stay
# relative to this live source-directory CWD.
VLC_SOURCE_WAS_CLONED=no
if [ -L vlc ]; then
    error "Refusing a symlinked VLC source directory: ${BUILD_DIR_DISPLAY}/vlc"
elif [ ! -e vlc ]; then
    info "Cloning VLC from ${VLC_REPO}..."
    git clone "${VLC_REPO}" --branch "${VLC_BRANCH}" --single-branch vlc
    VLC_SOURCE_WAS_CLONED=yes
elif [ ! -d vlc ]; then
    error "VLC source path is not a directory: ${BUILD_DIR_DISPLAY}/vlc"
fi
if ! bind_directory_for_handoff \
    . vlc "${VLC_SOURCE_BINDING_NAME}" "${VLC_SOURCE_BINDING_CONTENT}"; then
    error "Could not safely anchor the managed VLC source directory."
fi
cd vlc
retire_directory_binding \
    "${VLC_SOURCE_BINDING_NAME}" "${VLC_SOURCE_BINDING_CONTENT}" \
    "Managed VLC source directory"
VLC_SOURCE_DIRECTORY=$(/bin/pwd -P)
NATIVE_BUILD_PARENT=$(cd -P .. && /bin/pwd -P)
if [ "${EXTERNAL_BUILD_ROOT}" = yes ]; then
    if [ "${NATIVE_BUILD_PARENT}" != "${BUILD_DIR_DISPLAY}" ] || \
       [ "${VLC_SOURCE_DIRECTORY}" != "${BUILD_DIR_DISPLAY}/vlc" ]; then
        error "Managed native paths changed after they were anchored."
    fi
fi
# Keep generated libraries, validators, and release staging beneath this same
# anchored source CWD. Nothing later relies on `..`, whose parent relation
# could change if a non-cooperating process renamed the source directory.
BUILD_DIR="."
VLC_SRC="."
NATIVE_BUILD_DIRECTORY="${VLC_SOURCE_DIRECTORY}"

# A killed helper deliberately preserves state instead of guessing whether a
# pathname still identifies its original directory. Surface those exact
# source-root remnants before any new output stage can hide them among a
# multi-gigabyte VLC tree.
for preserved_source_state in \
    ./.swiftvlc-native-output \
    ./.swiftvlc-native-output.removing-* \
    ./.swiftvlc-managed-build.initializing-*; do
    if [ -e "${preserved_source_state}" ] || \
       [ -L "${preserved_source_state}" ]; then
        error "Found preserved native output state: ${preserved_source_state}. Inspect and recover or remove it before retrying."
    fi
done

if [ "${VLC_SOURCE_WAS_CLONED}" = yes ]; then
    git checkout -B build "${VLC_HASH}"
else
    # Only reset the whole checkout if HEAD isn't already at the pinned commit.
    # Step 1b verifies the exact ordered patch result and restores only
    # mismatching patch-owned paths, preserving source mtimes, unrelated
    # generated build-system changes, and per-platform build directories.
    # VideoLAN's GitLab also doesn't allow fetching by raw SHA, so skip the
    # fetch unless the commit is missing locally.
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
fi

# Resolve the requested revision to a full commit ID before applying any
# uncommitted source patches. This keeps build logs auditable even when VLC_HASH
# is abbreviated or overridden with --hash.
TARGET_SHA=$(git -C "${VLC_SRC}" rev-parse --verify "${VLC_HASH}^{commit}")
SOURCE_SHA=$(git -C "${VLC_SRC}" rev-parse --verify HEAD)
if [ "${SOURCE_SHA}" != "${TARGET_SHA}" ]; then
    error "VLC source revision mismatch: expected ${TARGET_SHA}, found ${SOURCE_SHA}"
fi
info "VLC source provenance: ${SOURCE_SHA}"

# Make compiler date/time macros deterministic. VLC's help object embeds
# __DATE__ and __TIME__; without SOURCE_DATE_EPOCH, two otherwise identical
# clean builds differ by their wall-clock compilation time. Deriving the
# epoch from the pinned commit makes it stable and auditable.
SOURCE_DATE_EPOCH=$(git -C "${VLC_SRC}" show -s --format=%ct "${SOURCE_SHA}")
if ! [[ "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]]; then
    error "Invalid SOURCE_DATE_EPOCH derived from ${SOURCE_SHA}"
fi
export SOURCE_DATE_EPOCH
info "Reproducible build epoch: ${SOURCE_DATE_EPOCH} (pinned commit timestamp)"

# Validator selectors are initialized even when no patch directory is active;
# later linked gates use them under `set -u` to choose the newest owner or an
# older fallback without depending on manifest-block scope.
chromecast_metadata_warning_patch_listed=no
chromecast_metadata_schema_patch_listed=no
chromecast_load_transition_patch_listed=no
apple_assembly_metadata_patch_listed=no
aom_nasm3_detection_patch_listed=no
headless_vout_teardown_patch_listed=no
adaptive_es_recycling_patch_listed=no
swiftvlc_manifest_extension_version=""
swiftvlc_apple_audio_session_leases_listed=no

# --- Step 1b: Apply patches ---
if [ -n "${PATCHES_DIR}" ] && [ -d "${PATCHES_DIR}" ]; then
    info "Applying patches from ${PATCHES_DIR}..."
    # The manifest, not the glob, decides which patches are applied and in what
    # order. An unlisted patch, a missing one, or an edited one is fatal — see
    # verify-patch-manifest.sh for why the binary's inputs have to be
    # answerable from the repository.
    #
    # Captured into a variable first rather than piped: a process substitution
    # would let a verification failure pass unnoticed, since the exit status of
    # `while read` is the loop's, not the producer's.
    if ! manifest_listing=$("${SCRIPT_DIR}/verify-patch-manifest.sh" "${PATCHES_DIR}"); then
        error "Patch manifest verification failed (see above)."
    fi
    manifest_order=()
    while IFS= read -r manifest_entry; do
        [ -n "$manifest_entry" ] || continue
        manifest_order+=("${PATCHES_DIR}/${manifest_entry}")
        manifest_extension_candidate=""
        case "$manifest_entry" in
            0004-samplebuffer-pip-safety-geometry.patch)
                manifest_extension_candidate=1 ;;
            0022-atomic-pip-playback-snapshot.patch)
                manifest_extension_candidate=2 ;;
            0024-native-pip-overlays.patch)
                manifest_extension_candidate=3 ;;
            0027-strict-frame-step-contract.patch)
                manifest_extension_candidate=4 ;;
            0029-sample-buffer-renderer-recovery.patch)
                manifest_extension_candidate=5 ;;
            0030-vmem-picture-pts.patch)
                manifest_extension_candidate=6 ;;
            0031-effective-playback-rate-event.patch)
                manifest_extension_candidate=7 ;;
            0032-audio-media-services-reset.patch)
                manifest_extension_candidate=8 ;;
            0033-apple-audio-session-policy-leases.patch)
                swiftvlc_apple_audio_session_leases_listed=yes ;;
            0041-native-pip-output-identity.patch)
                manifest_extension_candidate=9 ;;
            0043-text-subtitle-callback.patch)
                manifest_extension_candidate=10 ;;
        esac
        if [ -n "$manifest_extension_candidate" ] &&
           { [ -z "$swiftvlc_manifest_extension_version" ] ||
             [ "$manifest_extension_candidate" -gt "$swiftvlc_manifest_extension_version" ]; }; then
            swiftvlc_manifest_extension_version="$manifest_extension_candidate"
        fi
        if [ "$manifest_entry" = "0035-chromecast-metadata-warning.patch" ]; then
            chromecast_metadata_warning_patch_listed=yes
        fi
        if [ "$manifest_entry" = "0036-chromecast-metadata-schema-correctness.patch" ]; then
            chromecast_metadata_schema_patch_listed=yes
        fi
        if [ "$manifest_entry" = "0037-chromecast-load-transition-correctness.patch" ]; then
            chromecast_load_transition_patch_listed=yes
        fi
        if [ "$manifest_entry" = "0038-apple-assembly-metadata.patch" ]; then
            apple_assembly_metadata_patch_listed=yes
        fi
        if [ "$manifest_entry" = "0039-aom-3.13.2-nasm-detection.patch" ]; then
            aom_nasm3_detection_patch_listed=yes
        fi
        if [ "$manifest_entry" = "0040-headless-vout-teardown-deadlock.patch" ]; then
            headless_vout_teardown_patch_listed=yes
        fi
        if [ "$manifest_entry" = "0042-adaptive-es-recycling-extradata-identity.patch" ]; then
            adaptive_es_recycling_patch_listed=yes
        fi
    done <<< "$manifest_listing"
    info "Patch manifest verified: ${#manifest_order[@]} patches"

    # Patch 0038 changes the assembler tool recipe and command selection.
    # Incremental build roots can retain an older NASM path in contrib
    # configuration and old assembly objects in archives, so source replay is
    # insufficient evidence. Refuse every non-clean build while 0038 is part
    # of the selected manifest.
    if [ "$apple_assembly_metadata_patch_listed" = yes ] &&
       [ "$CLEAN_BUILD" != yes ]; then
        error "Patch 0038 requires --clean-build; cached tools, contrib configuration, or assembly objects cannot be reused."
    fi
    if [ "$aom_nasm3_detection_patch_listed" = yes ] &&
       [ "$CLEAN_BUILD" != yes ]; then
        error "Patch 0039 requires --clean-build; cached libaom configuration or objects cannot be reused."
    fi
    # Ordered patches can intentionally overlap (0003 refines code introduced
    # by 0002), which makes a per-patch reverse-check ambiguous on a subsequent
    # run. Build the expected final tree in a temporary Git index first. If the
    # working files already match that exact ordered result, leave them and their
    # mtimes untouched so an incremental invocation remains incremental. Only a
    # mismatch restores patch-owned paths to the pinned base and reapplies the
    # complete series. Build directories and unrelated source changes remain
    # intact.
    patch_files=()
    patch_paths=()
    for patch in "${manifest_order[@]}"; do
        if [ -f "$patch" ]; then
            patch_files+=("$patch")
            patch_numstat=$(git apply --numstat "$patch") \
                || error "Could not parse patch metadata: $(basename "$patch")"
            while IFS=$'\t' read -r _added _deleted patch_path; do
                [ -n "$patch_path" ] || continue
                case "$patch_path" in
                    /*|..|../*|*/..|*/../*) error "Unsafe path in patch $(basename "$patch"): ${patch_path}" ;;
                esac
                already_listed=no
                for existing_path in "${patch_paths[@]}"; do
                    if [ "$existing_path" = "$patch_path" ]; then
                        already_listed=yes
                        break
                    fi
                done
                if [ "$already_listed" = no ]; then
                    patch_paths+=("$patch_path")
                fi
            done <<< "$patch_numstat"
        fi
    done

    expected_index=$(mktemp "${TMPDIR:-/tmp}/swiftvlc-patches.XXXXXX")
    rm -f -- "$expected_index"
    if ! GIT_INDEX_FILE="$expected_index" git read-tree HEAD; then
        rm -f -- "$expected_index" "$expected_index.lock"
        error "Could not create the expected patch-series index"
    fi
    for patch in "${patch_files[@]}"; do
        if ! GIT_INDEX_FILE="$expected_index" git apply --cached "$patch"; then
            rm -f -- "$expected_index" "$expected_index.lock"
            error "Ordered patch series does not apply to ${SOURCE_SHA}: $(basename "$patch")"
        fi
    done

    patch_series_matches=yes
    for patch_path in "${patch_paths[@]}"; do
        expected_entry=$(GIT_INDEX_FILE="$expected_index" git ls-files -s -- "$patch_path")
        if [ -z "$expected_entry" ]; then
            if [ -e "$patch_path" ] || [ -L "$patch_path" ]; then
                patch_series_matches=no
                break
            fi
            continue
        fi

        expected_metadata=${expected_entry%%$'\t'*}
        read -r expected_mode expected_blob _stage <<< "$expected_metadata"
        if [ ! -e "$patch_path" ] && [ ! -L "$patch_path" ]; then
            patch_series_matches=no
            break
        fi
        current_blob=$(git hash-object -- "$patch_path")
        if [ "$current_blob" != "$expected_blob" ]; then
            patch_series_matches=no
            break
        fi
        case "$expected_mode" in
            100644) [ ! -x "$patch_path" ] || patch_series_matches=no ;;
            100755) [ -x "$patch_path" ] || patch_series_matches=no ;;
            120000) [ -L "$patch_path" ] || patch_series_matches=no ;;
        esac
        [ "$patch_series_matches" = yes ] || break
    done
    rm -f -- "$expected_index" "$expected_index.lock"

    if [ "$patch_series_matches" = yes ]; then
        for patch in "${patch_files[@]}"; do
            patch_name=$(basename "$patch")
            patch_sha=$(shasum -a 256 "$patch" | awk '{print $1}')
            info "  Verified in applied series: ${patch_name} (sha256 ${patch_sha})"
        done
    else
        for patch_path in "${patch_paths[@]}"; do
            if git cat-file -e "HEAD:${patch_path}" 2>/dev/null; then
                git checkout HEAD -- "$patch_path"
            else
                rm -f -- "$patch_path"
            fi
        done
        info "  Restored ${#patch_paths[@]} patch-owned source path(s) to ${SOURCE_SHA}"

        for patch in "${patch_files[@]}"; do
            patch_name=$(basename "$patch")
            patch_sha=$(shasum -a 256 "$patch" | awk '{print $1}')
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch"
                if ! git apply --reverse --check "$patch" 2>/dev/null; then
                    error "Patch verification failed after apply: ${patch_name}"
                fi
                info "  Applied: ${patch_name} (sha256 ${patch_sha})"
            elif git apply --reverse --check "$patch" 2>/dev/null; then
                info "  Already applied: ${patch_name} (sha256 ${patch_sha})"
            else
                warn "Patch is neither applicable nor already applied: ${patch_name}"
                git apply --check "$patch" 2>&1 || true
                error "Refusing to build with a conflicted or partially applied patch: ${patch_name}"
            fi
        done
    fi

    # This must be the first gate after the ordered replay. It validates the
    # exact 0038 source/tool contract before the build script performs any of
    # its dynamic source edits below.
    if [ "$apple_assembly_metadata_patch_listed" = yes ]; then
        info "Validating Apple assembly tool and Mach-O metadata source contract..."
        "${SCRIPT_DIR}/validate-apple-assembly-metadata-patch.sh" \
            "${VLC_SRC}" "${BUILD_DIR}/validation/0038-apple-assembly-metadata"
    fi

    if [ "$aom_nasm3_detection_patch_listed" = yes ]; then
        info "Validating libaom 3.13.2 and NASM 3 detection source contract..."
        "${SCRIPT_DIR}/validate-aom-nasm3-detection.sh" \
            "${VLC_SRC}" "${BUILD_DIR}/validation/0039-aom-nasm3-detection"
    fi

    if [ "$headless_vout_teardown_patch_listed" = yes ]; then
        info "Validating headless video-output teardown source contract..."
        "${SCRIPT_DIR}/validate-headless-vout-teardown.sh" \
            --source-root "${VLC_SRC}" \
            --work-root "${BUILD_DIR}/validation/0040-headless-vout-teardown"
    fi

    if [ "$adaptive_es_recycling_patch_listed" = yes ]; then
        info "Validating adaptive ES codec-configuration recycling contract..."
        python3 -B \
            "${SCRIPT_DIR}/patches/validation/adaptive-es-recycling-source-check.py" \
            "${VLC_SRC}" \
            "${SCRIPT_DIR}/patches/0042-adaptive-es-recycling-extradata-identity.patch"
    fi

    # Patches 0035–0037 deliberately change no public API, so they have no
    # additive source marker that can trigger a validator. Every successor
    # owns the inherited proof at its exact predecessor boundary, so run only
    # the newest listed contract. In particular, frozen 0036's fail-closed
    # mutation fixtures are valid on reconstructed 0036 source, not directly
    # on 0037's final source where new code may contain the same token.
    if [ "$chromecast_load_transition_patch_listed" = yes ]; then
        info "Validating Chromecast generation-safe load transitions and inherited metadata contracts..."
        "${SCRIPT_DIR}/validate-chromecast-load-transition.sh" \
            "${VLC_SRC}" "${BUILD_DIR}/validation/0037-chromecast-load-transition"
    elif [ "$chromecast_metadata_schema_patch_listed" = yes ]; then
        info "Validating Chromecast metadata schema and one-shot warnings..."
        "${SCRIPT_DIR}/validate-chromecast-metadata-schema.sh" \
            "${VLC_SRC}" "${BUILD_DIR}/validation/0036-chromecast-metadata-schema"
    elif [ "$chromecast_metadata_warning_patch_listed" = yes ]; then
        info "Validating Chromecast music metadata and one-shot warnings..."
        "${SCRIPT_DIR}/validate-chromecast-metadata-warning.sh" "${VLC_SRC}"
    fi
fi

# The ordered manifest, rather than whichever checked-in header happens to be
# present during a migration, owns the exact additive native ABI expected from
# this build. Clear inherited values first so custom manifests cannot silently
# validate against a caller's stale environment.
unset SWIFTVLC_EXPECTED_EXTENSION_VERSION
unset SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES
if [ "$swiftvlc_apple_audio_session_leases_listed" = yes ] &&
   { [ -z "$swiftvlc_manifest_extension_version" ] ||
     [ "$swiftvlc_manifest_extension_version" -lt 8 ]; }; then
    error "Patch 0033 requires manifest-owned extension version 8 or newer from patch 0032 and its successors."
fi
if [ -n "$swiftvlc_manifest_extension_version" ] &&
   [ "$swiftvlc_manifest_extension_version" -ge 9 ] &&
   [ "$swiftvlc_apple_audio_session_leases_listed" != yes ]; then
    error "Extension version 9 or newer requires the inherited patch 0033 Apple audio-session lease refinement."
fi
if [ -n "$swiftvlc_manifest_extension_version" ]; then
    export SWIFTVLC_EXPECTED_EXTENSION_VERSION="$swiftvlc_manifest_extension_version"
    export SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES="$swiftvlc_apple_audio_session_leases_listed"
    info "Selected native extension contract: version ${SWIFTVLC_EXPECTED_EXTENSION_VERSION}, Apple audio-session leases ${SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES}"

    # The shared composition resolver starts at strict frame-step version 4.
    # Versions 1-3 retain their feature-specific source checks and are still
    # bound across every produced archive by the linked contract below.
    if [ "$SWIFTVLC_EXPECTED_EXTENSION_VERSION" -ge 4 ]; then
        native_source_contract_args=(
            --source-root "$VLC_SRC"
            --expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"
            --run-mutations
        )
        if [ "$SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES" = yes ]; then
            native_source_contract_args+=(--require-apple-audio-session-leases)
        fi
        info "Validating the manifest-owned native extension source and vendored-header contract..."
        "${SCRIPT_DIR}/validate-native-extension-contract.sh" \
            "${native_source_contract_args[@]}"
    else
        info "Native extension versions 1-3 use their feature-specific source gates; exact archive validation will run for every produced slice."
    fi
elif grep -q 'swiftvlc_libvlc_pip_extensions_version' \
    "${VLC_SRC}/include/vlc/libvlc_media_player.h" 2>/dev/null; then
    error "Patched VLC source exposes a SwiftVLC native extension, but the selected manifest has no recognized extension-version owner."
else
    info "Selected patch manifest has no SwiftVLC native extension contract."
fi

# The libvlccore Darwin Objective-C target is compiled under ARC. Run the
# 0032/0033 structural/mutation/model proof before any architecture build so
# manual ownership or build-system drift fails in seconds instead of after the
# expensive contrib compilation. The configured-slice postflight below still
# owns the exact Apple SDK syntax proof.
if grep -q 'audioSessionMediaServicesWereReset:' \
       "${VLC_SRC}/modules/audio_output/apple/audiounit_ios.m" 2>/dev/null ||
   grep -q 'audioSessionMediaServicesWereReset:' \
       "${VLC_SRC}/modules/audio_output/apple/avsamplebuffer.m" 2>/dev/null; then
    info "Validating Apple audio reset/ownership ARC source contract before native compilation..."
    "${SCRIPT_DIR}/validate-audio-media-services-reset.sh" "${VLC_SRC}"
fi

# Exercise the exact production helper whenever this patch is in the engine
# source. CI links a released xcframework and cannot cover a newly added native
# patch until its beta exists, so engine builds themselves own this regression.
if [ -f "${VLC_SRC}/modules/video_output/apple/VLCSampleBufferFormatDescriptionCache.h" ]; then
    info "Validating native format-description cache reuse and invalidation..."
    "${SCRIPT_DIR}/validate-native-format-cache.sh" "${VLC_SRC}"
fi

if [ -f "${VLC_SRC}/modules/video_output/apple/VLCSampleBufferOverlayGeometry.h" ]; then
    info "Validating native PiP overlay geometry..."
    "${SCRIPT_DIR}/validate-native-pip-overlay-geometry.sh" "${VLC_SRC}"
    info "Validating native PiP overlay pixel formats and metadata..."
    "${SCRIPT_DIR}/validate-native-pip-overlay-pixels.sh"
fi

# Trigger on either half of the additive renderer API so a partial patch
# cannot evade validation. The validator requires both the deterministic
# recovery header and the public telemetry declaration.
if [ -f "${VLC_SRC}/modules/video_output/apple/VLCSampleBufferRendererRecovery.h" ] ||
   grep -q \
       'swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot' \
       "${VLC_SRC}/include/vlc/libvlc_media_player.h" 2>/dev/null; then
    info "Validating native sample-buffer renderer recovery contracts..."
    "${SCRIPT_DIR}/validate-sample-buffer-renderer-recovery.sh" "${VLC_SRC}"
fi

if grep -q 'swiftvlc_next_frame_request_result_t' \
    "${VLC_SRC}/include/vlc/libvlc_media_player.h"; then
    info "Validating strict frame-step terminal, reset, and reuse invariants..."
    python3 "${SCRIPT_DIR}/patches/validation/strict-frame-step-source-check.py" \
        "${VLC_SRC}"
fi

if grep -q 'swiftvlc_libvlc_video_set_callbacks_atomic_v2' \
    "${VLC_SRC}/include/vlc/libvlc_media_player.h"; then
    info "Validating v6 decoded-picture PTS source and ABI invariants..."
    "${SCRIPT_DIR}/validate-vmem-picture-pts.sh" "${VLC_SRC}"
fi

if grep -q 'libvlc_MediaPlayerRateChanged' \
    "${VLC_SRC}/include/vlc/libvlc_events.h"; then
    info "Validating effective playback-rate event source and ABI invariants..."
    "${SCRIPT_DIR}/validate-effective-playback-rate-event.sh" "${VLC_SRC}"
fi

# --- Step 1c: Patch VLC snapshot conversion owner ---
# VLC's snapshot path can convert a hardware/opaque picture to RGBA in order
# to blend a rendered subpicture into the saved PNG. At the pinned libVLC
# revision, that conversion filter chain is created with a video owner whose
# buffer allocator is NULL, but filter_chain_NewVideo() asserts that a parent
# video owner must provide one. This trips when snapshots are taken while SPU
# overlays/subtitles are active. Give the snapshot-only conversion chain a
# plain software picture allocator so the assertion and the conversion both
# have a valid output buffer.
patch_vlc_snapshot_filter_owner() {
    local VIDEO_OUTPUT_C="${VLC_SRC}/src/video_output/video_output.c"

    if grep -q 'VoutSnapshotFilterNewPicture' "$VIDEO_OUTPUT_C"; then
        info "VLC snapshot filter owner already patched"
        return 0
    fi

    info "Patching VLC snapshot filter owner buffer allocator..."

    python3 - "$VIDEO_OUTPUT_C" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

needle = '''static const struct filter_video_callbacks vout_video_cbs = {
    NULL, VoutHoldDecoderDevice,
};
'''

replacement = '''static picture_t *VoutSnapshotFilterNewPicture(filter_t *filter)
{
    return picture_NewFromFormat(&filter->fmt_out.video);
}

static const struct filter_video_callbacks vout_video_cbs = {
    VoutSnapshotFilterNewPicture, VoutHoldDecoderDevice,
};
'''

if needle not in content:
    raise SystemExit('snapshot filter callback block not found - VLC video_output.c shape changed')

content = content.replace(needle, replacement, 1)

with open(path, 'w') as f:
    f.write(content)

print('Snapshot filter owner patched successfully')
PYEOF

    info "VLC snapshot filter owner patched"
}

patch_vlc_snapshot_filter_owner

# --- Step 1d: Patch VLC for Mac Catalyst support ---
if [ "$BUILD_CATALYST" = "yes" ]; then
    patch_vlc_for_catalyst
fi

# --- Step 1e: Patch LDFLAGS to include -isysroot ---
# On Xcode 26+, the linker requires an explicit -isysroot
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

patch_vlc_xros_deployment_target() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"

    if grep -q 'SWIFTVLC_XROS_TARGET_TRIPLE' "$BUILD_SH"; then
        info "VLC build.sh already patched for visionOS deployment target"
        return 0
    fi

    info "Patching VLC build.sh to set visionOS deployment targets..."

    python3 - "$BUILD_SH" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]

with open(build_sh_path, 'r') as f:
    content = f.read()

needle = (
    '# Validate architecture argument\n'
    'validate_architecture "$VLC_HOST_ARCH"\n'
    '\n'
    '# Set triplet (needs to be called after validating the arch)\n'
)
replacement = (
    '# Validate architecture argument\n'
    'validate_architecture "$VLC_HOST_ARCH"\n'
    '\n'
    '# SWIFTVLC_XROS_TARGET_TRIPLE: the pinned VLC build script leaves xrOS\n'
    '# min-version flags empty, which makes clang stamp objects with the SDK\n'
    '# version. Use a target triple so visionOS objects keep SwiftVLC\'s minimum.\n'
    'if [ "$VLC_HOST_OS" = "xros" ]; then\n'
    '    xros_simulator_suffix=""\n'
    '    if [ -n "$VLC_HOST_PLATFORM_SIMULATOR" ]; then\n'
    '        xros_simulator_suffix="-simulator"\n'
    '    fi\n'
    '    VLC_DEPLOYMENT_TARGET_CFLAG="--target=${VLC_HOST_ARCH}-apple-xros${VLC_DEPLOYMENT_TARGET}${xros_simulator_suffix}"\n'
    '    VLC_DEPLOYMENT_TARGET_LDFLAG="${VLC_DEPLOYMENT_TARGET_CFLAG}"\n'
    'fi\n'
    '\n'
    '# Set triplet (needs to be called after validating the arch)\n'
)
if needle not in content:
    raise SystemExit('architecture validation block not found — VLC build.sh shape changed')

content = content.replace(needle, replacement, 1)

with open(build_sh_path, 'w') as f:
    f.write(content)

print('visionOS deployment target patch applied successfully')
PYEOF

    info "VLC build.sh visionOS deployment target patched"
}

patch_vlc_xros_deployment_target

patch_vlc_deployment_targets() {
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"
    local deployment_result

    deployment_result=$(python3 - "$BUILD_CONF" \
        "$SWIFTVLC_MIN_MACOS" \
        "$SWIFTVLC_MIN_IOS" \
        "$SWIFTVLC_MIN_TVOS" \
        "$SWIFTVLC_MIN_CATALYST" \
        "$SWIFTVLC_MIN_VISIONOS" << 'PYEOF'
import re
import sys

build_conf_path, macos, ios, tvos, catalyst, visionos = sys.argv[1:]

with open(build_conf_path, 'r') as f:
    content = f.read()
original = content

replacements = {
    r'^export VLC_DEPLOYMENT_TARGET_MACOSX=.*$': f'export VLC_DEPLOYMENT_TARGET_MACOSX="{macos}"',
    r'^export VLC_DEPLOYMENT_TARGET_IOS=.*$': f'export VLC_DEPLOYMENT_TARGET_IOS="{ios}"',
    r'^export VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR=.*$': f'export VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR="{ios}"',
    r'^export VLC_DEPLOYMENT_TARGET_TVOS=.*$': f'export VLC_DEPLOYMENT_TARGET_TVOS="{tvos}"',
    r'^export VLC_DEPLOYMENT_TARGET_TVOS_SIMULATOR=.*$': f'export VLC_DEPLOYMENT_TARGET_TVOS_SIMULATOR="{tvos}"',
    r'^export VLC_DEPLOYMENT_TARGET_XROS=.*$': f'export VLC_DEPLOYMENT_TARGET_XROS="{visionos}"',
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

if content == original:
    print('unchanged')
else:
    with open(build_conf_path, 'w') as f:
        f.write(content)
    print('changed')
PYEOF
    )

    if [ "$deployment_result" = "changed" ]; then
        info "VLC deployment targets patched to SwiftVLC minimums"
    elif [ "$deployment_result" = "unchanged" ]; then
        info "VLC deployment targets already match SwiftVLC minimums"
    else
        error "Unexpected deployment-target patch result: ${deployment_result}"
    fi
}

patch_vlc_deployment_targets

# --- Step 1f: Force libtool --tag=CC for Objective-C convenience library ---
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
           "${VLC_SRC}"/build-xros-* \
           "${VLC_SRC}"/build-xrsimulator-* \
           "${VLC_SRC}"/build-macosx-* \
           "${VLC_SRC}"/build-maccatalyst-*

    info "Makefile.am files patched; configure + platform build dirs cleared"
}

patch_vlc_objc_libtool

# --- Step 1g: Disable Rust-based contribs ---
# VLC contribs pin cargo-c 0.9.29, which transitively pulls time 0.3.31 and
# fails type inference for Box<_> under the supported Rust toolchain.
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
    '# SWIFTVLC_DISABLE_RUST: cargo-c 0.9.29 pulls time 0.3.31, which fails\n'
    '# type inference for Box<_>; rav1e is an encoder and dav1d handles\n'
    '# AV1 decoding. Never set BUILD_RUST.\n'
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
HOST_BUILD_PATH="$PATH"
(
cd "${VLC_SRC}/extras/tools"
TOOLS_SOURCE_DIRECTORY=$(/bin/pwd -P)
export PATH="${TOOLS_SOURCE_DIRECTORY}/build/bin:${HOST_BUILD_PATH}"
./bootstrap
make ${MAKEFLAGS}
)
VLC_TOOLS_BIN=$(cd "${VLC_SRC}/extras/tools/build/bin" && /bin/pwd -P)
export PATH="${VLC_TOOLS_BIN}:${HOST_BUILD_PATH}"

# Patches 0028/0034's linked gates use the tools produced above. Run them
# before any platform compile so malformed Cast JSON handling, unreachable
# address publication, duration classification, or UPnP lifecycle regressions
# fail once rather than once per slice. Keep all generated probe objects under
# the external build root.
if [ -f "${VLC_SRC}/modules/stream_out/chromecast/chromecast_protocol.hpp" ]; then
    if [ "$chromecast_load_transition_patch_listed" != yes ] &&
       [ -f "${VLC_SRC}/modules/stream_out/chromecast/chromecast_demux_eof.hpp" ]; then
        info "Validating Chromecast clock, attribution, transport, and EOF invariants..."
        "${SCRIPT_DIR}/validate-chromecast-state.sh" \
            "${VLC_SRC}" "${BUILD_DIR}/validation"
    fi
    info "Validating post-pin playback, UPnP, and Chromecast invariants..."
    "${SCRIPT_DIR}/validate-post-pin-stability.sh" \
        "${VLC_SRC}" "${BUILD_DIR}/validation"
fi

# --- Step 3: Compile libVLC per platform/arch ---
#
# Force autoconf to treat Linux-only syscalls as unavailable. iOS Simulator
# SDK 26+ exports dup3/pipe2 from libSystem (so autoconf's link test says
# "yes"), but the iOS headers don't declare them — leading to
# "use of undeclared identifier 'dup3'" during src/posix/filesystem.c.
# Device builds correctly detect "no"; simulator SDKs that expose those
# symbols get confused. VLC's code has proper #else fallbacks.
export ac_cv_func_dup3=no
export ac_cv_func_pipe2=no

# Translate WITH_ASSERTS into VLC's configure flag, computed once and forwarded
# to every per-platform build below. --disable-debug defines NDEBUG, which turns
# assert() into a no-op so "should not happen" guards (e.g. hxxx_helper.c:565)
# fall through to their graceful return instead of abort()ing the host process.
# The array stays empty when asserts are enabled, expanding to zero arguments
# (safe: the script uses `set -e` but not `set -u`).
VLC_DEBUG_ARGS=()
if [ "$WITH_ASSERTS" = "no" ]; then
    VLC_DEBUG_ARGS+=( "--disable-debug" )
    info "Run-time assertions disabled (release default)"
else
    info "Run-time assertions ENABLED (debugging build)"
fi

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
    (
    cd "${BUILDDIR}"

    PATH="${VLC_TOOLS_BIN}:${HOST_BUILD_PATH}" \
    "../extras/package/apple/build.sh" \
        --arch="${ARCH}" \
        --sdk="${PLATFORM}${SDK_VERSION}" \
        "${VLC_DEBUG_ARGS[@]}" \
        ${MAKEFLAGS}
    )

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
    (
    cd "${BUILDDIR}"

    PATH="${VLC_TOOLS_BIN}:${HOST_BUILD_PATH}" \
    "../extras/package/apple/build.sh" \
        --arch="${ARCH}" \
        --sdk="macosx${SDK_VERSION}" \
        --catalyst \
        "${VLC_DEBUG_ARGS[@]}" \
        ${MAKEFLAGS}
    )

    local platform_end=$(date +%s)
    local platform_secs=$((platform_end - platform_start))
    local platform_mins=$((platform_secs / 60))
    info "Finished ${ACTUAL_ARCH} (Mac Catalyst) in ${platform_mins}m$((platform_secs % 60))s"
}

# Every slice below ships headers from ${REPO_ROOT}/Sources/CLibVLC/include --
# a git-tracked copy of the libVLC public headers -- and NOT from the patched
# ${VLC_SRC}/include. That same directory is what SwiftPM compiles against.
#
# So a patch in scripts/patches that changes a public header has to change the
# vendored copy too, or the change reaches the compiled library and no consumer
# can see it. Patch 0015 hit exactly that: it added a `reason` field that the
# library populated while every shipped header still declared the struct
# without it.
#
# The two trees are deliberately not byte-identical (the vendored copies carry
# fuller doc comments), so there is no equality gate here. The guard is
# Tests/SwiftVLCTests/Core/VendoredHeaderParityTests.swift, which reaches the
# patched declarations through CLibVLC and stops compiling if they go missing.
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

    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/ios-device/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/ios-simulator/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
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

    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/tvos-device/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/tvos-simulator/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

if [ "$BUILD_VISIONOS" = "yes" ]; then
    compile_libvlc aarch64 xros
    compile_libvlc aarch64 xrsimulator
    compile_libvlc x86_64 xrsimulator

    mkdir -p "${BUILD_DIR}/libs/visionos-simulator"
    lipo \
        "${VLC_SRC}/build-xrsimulator-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-xrsimulator-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/visionos-simulator/libvlc.a"

    mkdir -p "${BUILD_DIR}/libs/visionos-device"
    cp "${VLC_SRC}/build-xros-arm64/static-lib/libvlc-full-static.a" \
       "${BUILD_DIR}/libs/visionos-device/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/visionos-device/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/visionos-simulator/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

if [ "$BUILD_MACOS" = "yes" ]; then
    compile_libvlc aarch64 macosx
    compile_libvlc x86_64 macosx

    mkdir -p "${BUILD_DIR}/libs/macos"
    lipo \
        "${VLC_SRC}/build-macosx-arm64/static-lib/libvlc-full-static.a" \
        "${VLC_SRC}/build-macosx-x86_64/static-lib/libvlc-full-static.a" \
        -create -output "${BUILD_DIR}/libs/macos/libvlc.a"

    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/macos/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
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

    XCFRAMEWORK_ARGS+=(-library "${NATIVE_BUILD_DIRECTORY}/libs/maccatalyst/libvlc.a" -headers "${REPO_ROOT}/Sources/CLibVLC/include")
fi

# --- Step 4: Create XCFramework ---
if [ ${#XCFRAMEWORK_ARGS[@]} -eq 0 ]; then
    error "No platforms were built. Use --macos, --ios-only, --tvos-only, --visionos-only, --catalyst-only, --tvos, --visionos, --macos, --catalyst, or --all"
fi

# Build and validate the complete release payload beneath the already-anchored
# VLC source CWD. Vendor is touched again only during the final bound publish,
# so replacing the checkout path during a long native build cannot redirect
# any intermediate deletion or mutation.
STAGED_OUTPUT_CHILD=".swiftvlc-native-output"
if [ -e "${STAGED_OUTPUT_CHILD}" ] || [ -L "${STAGED_OUTPUT_CHILD}" ]; then
    error "Stable native output staging path already exists; inspect or clean the managed build before retrying: ${STAGED_OUTPUT_CHILD}"
fi
if ! PYTHONDONTWRITEBYTECODE=1 python3 \
    "${SCRIPT_DIR}/detach-managed-build-directory.py" initialize \
    --root . \
    --child "${STAGED_OUTPUT_CHILD}" \
    --marker-name "${STAGED_OUTPUT_MARKER}" \
    --marker-content "${STAGED_OUTPUT_MARKER_CONTENT}" \
    --binding-name "${STAGED_OUTPUT_BINDING_NAME}" \
    --binding-content "${STAGED_OUTPUT_BINDING_CONTENT}" \
    --require-new; then
    error "Could not create stable native output staging directory."
fi
PUBLISHED_OUTPUT_DIR="${REPO_ROOT}/Vendor"
(
cd "${STAGED_OUTPUT_CHILD}"
verify_directory_binding \
    "${STAGED_OUTPUT_BINDING_NAME}" "${STAGED_OUTPUT_BINDING_CONTENT}" \
    "Native output staging directory"
STAGED_OUTPUT_DIRECTORY=$(/bin/pwd -P)
if [ "${STAGED_OUTPUT_DIRECTORY}" != \
     "${VLC_SOURCE_DIRECTORY}/${STAGED_OUTPUT_CHILD}" ]; then
    error "Native output staging path changed before it was anchored."
fi
OUTPUT_DIR="."
# The output phase remains in its own anchored CWD. Source inputs use the
# physical path captured while the parent shell was still anchored in VLC.
VLC_SRC="${VLC_SOURCE_DIRECTORY}"
BUILD_DIR="${NATIVE_BUILD_DIRECTORY}"

info "Creating libvlc.xcframework..."
MACHO_METADATA_REPORT="${OUTPUT_DIR}/libvlc-macho-metadata.json"

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "${OUTPUT_DIR}/libvlc.xcframework"

# xcodebuild writes AvailableLibraries in completion order rather than input
# order, so two identical builds can serialize the same slice records in a
# different sequence. Canonicalize the list and dictionary keys before hashing
# or publishing the artifact.
info "Normalizing XCFramework metadata..."
python3 - "${OUTPUT_DIR}/libvlc.xcframework/Info.plist" <<'PYEOF'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or not libraries:
    raise SystemExit(f"Error: {path} has no AvailableLibraries")
identifiers = [item.get("LibraryIdentifier") for item in libraries]
if any(not isinstance(identifier, str) or not identifier for identifier in identifiers):
    raise SystemExit(f"Error: {path} has an invalid library identifier")
if len(set(identifiers)) != len(identifiers):
    raise SystemExit(f"Error: {path} has duplicate library identifiers")
info["AvailableLibraries"] = sorted(
    libraries,
    key=lambda item: item["LibraryIdentifier"],
)
path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
PYEOF

# Fix duplicate symbols (json_parse_error/json_read) in the static library.
# Two VLC plugins (ytdl, chromecast) each compile their own copy. The Apple
# linker in Xcode 16+ treats these as errors on some platforms (Mac Catalyst).
info "Fixing duplicate symbols in static libraries..."
"${SCRIPT_DIR}/fix-duplicate-symbols.sh" "${OUTPUT_DIR}/libvlc.xcframework"

# Patch 0020 extends EncounteredError with subsystem attribution. Compile and
# execute its source/demux/decoder fixtures against the exact archive and
# vendored headers about to ship, rather than merely proving the engine source
# compiled. iOS-only builds have no host-runnable slice and skip this gate.
if grep -q 'libvlc_playback_failure_kind_t' \
    "${REPO_ROOT}/Sources/CLibVLC/include/vlc/libvlc_events.h"; then
    info "Validating terminal playback failure attribution..."
    "${SCRIPT_DIR}/validate-playback-failure-kind.sh" \
        "${OUTPUT_DIR}/libvlc.xcframework"
fi

if grep -q 'bool seekable;' \
    "${REPO_ROOT}/Sources/CLibVLC/include/vlc/libvlc_media_player.h"; then
    info "Validating atomic PiP playback snapshots..."
    "${SCRIPT_DIR}/validate-pip-playback-snapshot.sh" \
        "${OUTPUT_DIR}/libvlc.xcframework"
fi

if [ "$headless_vout_teardown_patch_listed" = yes ] && [ "$BUILD_MACOS" = "yes" ]; then
    info "Validating bounded headless video-output stop and natural-EOF teardown..."
    "${SCRIPT_DIR}/validate-headless-vout-teardown.sh" \
        --source-root "${VLC_SRC}" \
        --xcframework "${OUTPUT_DIR}/libvlc.xcframework" \
        --work-root "${BUILD_DIR}/validation/0040-headless-vout-teardown-runtime"
fi

if grep -q 'swiftvlc_next_frame_request_result_t' \
    "${REPO_ROOT}/Sources/CLibVLC/include/vlc/libvlc_media_player.h"; then
    if [ "$BUILD_MACOS" = "yes" ]; then
        HOST_MACOS_ARCH=$(uname -m)
        case "$HOST_MACOS_ARCH" in
            arm64|x86_64) ;;
            *) error "Unsupported macOS validation host architecture: $HOST_MACOS_ARCH" ;;
        esac
        STRICT_MACOS_BUILD_CONTAINER="${VLC_SRC}/build-macosx-${HOST_MACOS_ARCH}"
        if [ -f "${STRICT_MACOS_BUILD_CONTAINER}/config.h" ]; then
            STRICT_MACOS_BUILD_ROOT="${STRICT_MACOS_BUILD_CONTAINER}"
        elif [ -f "${STRICT_MACOS_BUILD_CONTAINER}/build/config.h" ]; then
            # VLC's Apple build driver configures out-of-tree builds in this
            # nested directory while keeping static-lib beside it.
            STRICT_MACOS_BUILD_ROOT="${STRICT_MACOS_BUILD_CONTAINER}/build"
        else
            error "Strict frame-step host build root is incomplete: ${STRICT_MACOS_BUILD_CONTAINER}"
        fi
        info "Validating strict request-correlated frame stepping with source-linked race gates..."
        "${SCRIPT_DIR}/validate-strict-frame-step.sh" \
            "${OUTPUT_DIR}/libvlc.xcframework" \
            "${VLC_SRC}" "${STRICT_MACOS_BUILD_ROOT}"
    else
        info "Strict frame-step runtime and source-linked listener/overflow/vmem race gates skipped: no macOS slice was selected (iOS/device-only build)."
    fi
fi

if grep -q 'libvlc_MediaPlayerRateChanged' \
    "${VLC_SRC}/include/vlc/libvlc_events.h"; then
    if [ "$BUILD_MACOS" = "yes" ]; then
        HOST_MACOS_ARCH=$(uname -m)
        case "$HOST_MACOS_ARCH" in
            arm64|x86_64) ;;
            *) error "Unsupported macOS rate-event validation host architecture: $HOST_MACOS_ARCH" ;;
        esac
        RATE_EVENT_MACOS_BUILD_ROOT="${VLC_SRC}/build-macosx-${HOST_MACOS_ARCH}"
        info "Validating exact effective playback-rate event source syntax..."
        "${SCRIPT_DIR}/validate-effective-playback-rate-event.sh" \
            "${VLC_SRC}" "${RATE_EVENT_MACOS_BUILD_ROOT}" \
            "${OUTPUT_DIR}/libvlc.xcframework"
    else
        info "Effective playback-rate event source syntax gate skipped: no macOS slice was selected."
    fi
fi

if grep -q 'swiftvlc_libvlc_video_set_callbacks_atomic_v2' \
    "${VLC_SRC}/include/vlc/libvlc_media_player.h"; then
    if [ "$BUILD_MACOS" = "yes" ]; then
        HOST_MACOS_ARCH=$(uname -m)
        case "$HOST_MACOS_ARCH" in
            arm64|x86_64) ;;
            *) error "Unsupported macOS vmem validation host architecture: $HOST_MACOS_ARCH" ;;
        esac
        VMEM_PTS_MACOS_BUILD_ROOT="${VLC_SRC}/build-macosx-${HOST_MACOS_ARCH}"
        info "Validating linked v6 decoded-picture PTS delivery and generation races..."
        "${SCRIPT_DIR}/validate-vmem-picture-pts.sh" \
            "${VLC_SRC}" "${VMEM_PTS_MACOS_BUILD_ROOT}" \
            "${OUTPUT_DIR}/libvlc.xcframework"
    else
        info "v6 decoded-picture PTS runtime gate skipped: no macOS slice was selected."
    fi
fi

# Patches 0032/0033 harden both Apple audio-output implementations and route
# reset recovery plus optional application ownership through one process
# broker. The source proof already ran before native compilation; repeat it
# after all selected slices finish and type-check against one exact configured
# Apple device build when the build includes a platform that uses
# AVAudioSession.
if grep -q 'audioSessionMediaServicesWereReset:' \
       "${VLC_SRC}/modules/audio_output/apple/audiounit_ios.m" 2>/dev/null ||
   grep -q 'audioSessionMediaServicesWereReset:' \
       "${VLC_SRC}/modules/audio_output/apple/avsamplebuffer.m" 2>/dev/null; then
    AUDIO_RESET_BUILD_ROOT=""
    AUDIO_RESET_SDK=""
    AUDIO_RESET_DEPLOYMENT=""
    if [ "$BUILD_IOS" = "yes" ]; then
        AUDIO_RESET_BUILD_ROOT="${VLC_SRC}/build-iphoneos-arm64"
        AUDIO_RESET_SDK="iphoneos"
        AUDIO_RESET_DEPLOYMENT="${SWIFTVLC_MIN_IOS}"
    elif [ "$BUILD_TVOS" = "yes" ]; then
        AUDIO_RESET_BUILD_ROOT="${VLC_SRC}/build-appletvos-arm64"
        AUDIO_RESET_SDK="appletvos"
        AUDIO_RESET_DEPLOYMENT="${SWIFTVLC_MIN_TVOS}"
    elif [ "$BUILD_VISIONOS" = "yes" ]; then
        AUDIO_RESET_BUILD_ROOT="${VLC_SRC}/build-xros-arm64"
        AUDIO_RESET_SDK="xros"
        AUDIO_RESET_DEPLOYMENT="${SWIFTVLC_MIN_VISIONOS}"
    elif [ "$BUILD_CATALYST" = "yes" ]; then
        AUDIO_RESET_BUILD_ROOT="${VLC_SRC}/build-maccatalyst-arm64"
        AUDIO_RESET_SDK="maccatalyst"
        AUDIO_RESET_DEPLOYMENT="${SWIFTVLC_MIN_CATALYST}"
    fi

    if [ -n "$AUDIO_RESET_BUILD_ROOT" ]; then
        info "Validating Apple audio reset recovery, ownership policy, and leases against ${AUDIO_RESET_SDK}..."
        "${SCRIPT_DIR}/validate-audio-media-services-reset.sh" \
            "${VLC_SRC}" "${AUDIO_RESET_BUILD_ROOT}" \
            "${AUDIO_RESET_SDK}" "${AUDIO_RESET_DEPLOYMENT}"
    else
        info "Validating Apple audio reset/ownership source contract (no AVAudioSession device slice selected)..."
        "${SCRIPT_DIR}/validate-audio-media-services-reset.sh" "${VLC_SRC}"
    fi
fi

# Remove the CLibVLC module.modulemap from xcframework headers to avoid
# "redefinition of module" errors when building with xcodebuild. The CLibVLC
# SPM target provides its own module map; the xcframework only needs the raw
# VLC C headers.
find "${OUTPUT_DIR}/libvlc.xcframework" -name "module.modulemap" -delete
find "${OUTPUT_DIR}/libvlc.xcframework" -name "CLibVLC.h" -delete

info "Stripping release debug symbols before reproducibility hashing..."
find "${OUTPUT_DIR}/libvlc.xcframework" -name '*.a' -exec strip -S {} \;

# `strip` rebuilds each archive's __.SYMDEF member and stamps that member with
# the current wall-clock time. The object payloads are unchanged, but those few
# header bytes make otherwise identical clean builds hash differently. Reset
# the archive indexes after the final mutating step so provenance covers the
# exact deterministic artifact that will be released.
info "Normalizing archive indexes after stripping..."
find "${OUTPUT_DIR}/libvlc.xcframework" -name '*.a' -exec xcrun ranlib -D {} \;

# The external working root is intentionally stable across clean builds, but
# the two SwiftVLC checkout paths must remain independent. Reject any future
# build-system change that copies a checkout-local absolute path into a shipped
# library or header; such a leak would make the proof location-dependent again.
if [ "${EXTERNAL_BUILD_ROOT}" = yes ]; then
    info "Verifying that the release artifact contains no checkout-local paths..."
    verify_checkout_path_not_embedded
fi

# Re-evaluate the manifest-owned identity across every exact archive after the
# final archive mutation. The central gate inspects every declared architecture
# and additionally executes its probe when a host-runnable macOS slice exists.
if [ -n "$swiftvlc_manifest_extension_version" ]; then
    native_archive_contract_args=(
        --xcframework "${OUTPUT_DIR}/libvlc.xcframework"
        --expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"
    )
    if [ "$SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES" = yes ]; then
        native_archive_contract_args+=(--require-apple-audio-session-leases)
    fi
    info "Validating the exact linked native extension archive contract across every produced slice..."
    "${SCRIPT_DIR}/validate-native-extension-contract.sh" \
        "${native_archive_contract_args[@]}"
fi

info "Created: ${OUTPUT_DIR}/libvlc.xcframework"

# --- Step 5: Verify every shipped Mach-O object ---
#
# A slice-level `otool` maximum can neither detect assembly objects with no
# platform command nor prove that every object names the right Apple platform.
# Parse the universal archives and their Mach-O members directly instead. The
# gate requires exactly one LC_BUILD_VERSION with the exact deployment target,
# rejects legacy platform commands, validates CPU attribution, and caps section
# alignment so an accidental Mach-O `.align 16` cannot request 64 KiB.
info "Verifying per-object Mach-O platform metadata and section alignment..."
PYTHONDONTWRITEBYTECODE=1 python3 \
    "${SCRIPT_DIR}/validate-libvlc-macho-metadata.py" \
    --xcframework "${OUTPUT_DIR}/libvlc.xcframework" \
    --deployment-target "ios=${SWIFTVLC_MIN_IOS}" \
    --deployment-target "tvos=${SWIFTVLC_MIN_TVOS}" \
    --deployment-target "xros=${SWIFTVLC_MIN_VISIONOS}" \
    --deployment-target "macos=${SWIFTVLC_MIN_MACOS}" \
    --deployment-target "catalyst=${SWIFTVLC_MIN_CATALYST}" \
    --json-output "${MACHO_METADATA_REPORT}"
info "Verified every Mach-O object; report: ${MACHO_METADATA_REPORT}"

# --- Step 6: Record the verified, release-ready artifact ---
#
# Provenance is deliberately written only after the complete per-object metadata
# gate passes. The artifact is also stripped above, before hashing, so the two-
# clean-build proof covers the exact tree release.sh packages. Final publication
# copies that immutable tree into an invocation-private Vendor staging directory
# and verifies the provenance tree digest again before replacing the old output.
if [ "${CLEAN_BUILD}" = yes ]; then
    # Recheck after compilation so a checkout edit or branch move during the
    # long build cannot be attributed to the revision captured at startup.
    verify_clean_swiftvlc_checkout
fi
PROVENANCE_FILE="${OUTPUT_DIR}/libvlc-provenance.json"
provenance_args=(
    python3 "${SCRIPT_DIR}/libvlc-provenance.py" create
    --xcframework "${OUTPUT_DIR}/libvlc.xcframework"
    --output "${PROVENANCE_FILE}"
    --vlc-source "${VLC_SRC}"
    --swiftvlc-revision "${SWIFTVLC_REVISION}"
    --source-revision "${SOURCE_SHA}"
    --pinned-revision "${VLC_HASH}"
    --source-date-epoch "${SOURCE_DATE_EPOCH}"
    --build-invocation-id "${BUILD_INVOCATION_ID}"
    --build-configuration-file "build-libvlc.sh=${SCRIPT_DIR}/build-libvlc.sh"
    --build-configuration-file "detach-managed-build-directory.py=${SCRIPT_DIR}/detach-managed-build-directory.py"
    --build-configuration-file "fix-duplicate-symbols.sh=${SCRIPT_DIR}/fix-duplicate-symbols.sh"
    --build-configuration-file "validate-libvlc-macho-metadata.py=${SCRIPT_DIR}/validate-libvlc-macho-metadata.py"
    --build-configuration-file "verify-libvlc-build-paths.py=${SCRIPT_DIR}/verify-libvlc-build-paths.py"
    --build-configuration-file "validate-apple-assembly-metadata-patch.sh=${SCRIPT_DIR}/validate-apple-assembly-metadata-patch.sh"
    --build-configuration-file "validate-aom-nasm3-detection.sh=${SCRIPT_DIR}/validate-aom-nasm3-detection.sh"
    --build-configuration-file "validate-headless-vout-teardown.sh=${SCRIPT_DIR}/validate-headless-vout-teardown.sh"
    --build-configuration-file "validate-chromecast-load-transition.sh=${SCRIPT_DIR}/validate-chromecast-load-transition.sh"
    --build-configuration-file "validate-native-extension-contract.sh=${SCRIPT_DIR}/validate-native-extension-contract.sh"
    --build-configuration-file "native-extension-version-probe.c=${SCRIPT_DIR}/patches/validation/native-extension-version-probe.c"
    --build-configuration-file "pip_extension_version.py=${SCRIPT_DIR}/patches/validation/pip_extension_version.py"
    --build-configuration-file "validate-post-pin-stability.sh=${SCRIPT_DIR}/validate-post-pin-stability.sh"
    --build-configuration-file "native-validator-assets.sha256=${SCRIPT_DIR}/native-validator-assets.sha256"
    --build-configuration-file "verify-native-validator-assets.py=${SCRIPT_DIR}/verify-native-validator-assets.py"
    --make-flags="${MAKEFLAGS}"
    --deployment-target "ios=${SWIFTVLC_MIN_IOS}"
    --deployment-target "tvos=${SWIFTVLC_MIN_TVOS}"
    --deployment-target "xros=${SWIFTVLC_MIN_VISIONOS}"
    --deployment-target "macos=${SWIFTVLC_MIN_MACOS}"
    --deployment-target "catalyst=${SWIFTVLC_MIN_CATALYST}"
)
if [ -n "${PATCHES_DIR}" ] && [ -f "${PATCHES_DIR}/manifest.sha256" ]; then
    provenance_args+=(--patch-manifest "${PATCHES_DIR}/manifest.sha256")
fi
if [ "${WITH_ASSERTS}" = "yes" ]; then
    provenance_args+=(--assertions-enabled)
fi
if [ "${CLEAN_BUILD}" = "yes" ]; then
    provenance_args+=(--clean-build)
fi
"${provenance_args[@]}"
info "Recorded verified build provenance: ${PROVENANCE_FILE}"

# Publish only the fully validated payload. The helper binds the exact Vendor
# directory without following a symlink; the publishing shell then stays in
# that directory and uses only direct relative destinations. A checkout-path
# replacement therefore cannot redirect deletion into unrelated data.
if [ "$(/bin/pwd -P)" != "${STAGED_OUTPUT_DIRECTORY}" ]; then
    error "Native output staging path changed before artifact publication."
fi
verify_directory_binding \
    "${STAGED_OUTPUT_BINDING_NAME}" "${STAGED_OUTPUT_BINDING_CONTENT}" \
    "Native output staging directory"
STAGED_OUTPUT_DIRECTORY=$(cd "${OUTPUT_DIR}" && /bin/pwd -P)
if [ "${STAGED_OUTPUT_DIRECTORY}" != \
     "${VLC_SOURCE_DIRECTORY}/${STAGED_OUTPUT_CHILD}" ]; then
    error "Invocation output path changed before publication."
fi
STAGED_PROVENANCE_SHA256=$(shasum -a 256 \
    "${STAGED_OUTPUT_DIRECTORY}/libvlc-provenance.json" | awk '{print $1}')
STAGED_MACHO_REPORT_SHA256=$(shasum -a 256 \
    "${STAGED_OUTPUT_DIRECTORY}/libvlc-macho-metadata.json" | awk '{print $1}')
if ! [[ "${STAGED_PROVENANCE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
   ! [[ "${STAGED_MACHO_REPORT_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
    error "Could not capture exact staged-output identities before publication."
fi
(
cd "${REPO_ROOT}/Vendor"
retire_directory_binding \
    "${OUTPUT_BINDING_NAME}" "${OUTPUT_BINDING_CONTENT}" \
    "Checkout Vendor output directory"

PUBLISHING_CHILD=".swiftvlc-native-output-publishing-${BUILD_INVOCATION_ID}"
if ! bind_directory_for_handoff \
    . "${PUBLISHING_CHILD}" \
    "${PUBLISHING_BINDING_NAME}" "${PUBLISHING_BINDING_CONTENT}" \
    --create; then
    error "Could not safely initialize the Vendor publication staging directory."
fi
(
cd "${PUBLISHING_CHILD}"
verify_directory_binding \
    "${PUBLISHING_BINDING_NAME}" "${PUBLISHING_BINDING_CONTENT}" \
    "Vendor publication staging directory"
/usr/bin/ditto \
    "${STAGED_OUTPUT_DIRECTORY}/libvlc.xcframework" \
    ./libvlc.xcframework
cp -p "${STAGED_OUTPUT_DIRECTORY}/libvlc-provenance.json" \
    ./libvlc-provenance.json
cp -p "${STAGED_OUTPUT_DIRECTORY}/libvlc-macho-metadata.json" \
    ./libvlc-macho-metadata.json

# libvlc-provenance.py's tree identity includes entry kinds, permissions,
# symlink targets, and file bytes. First bind the copied provenance/report to
# hashes captured while the source CWD was still anchored, then verify the copy
# against that immutable provenance record. Re-reading a replaceable source
# pathname can therefore never make two attacker substitutions compare equal.
PUBLISHED_PROVENANCE_SHA256=$(shasum -a 256 \
    ./libvlc-provenance.json | awk '{print $1}')
PUBLISHED_MACHO_REPORT_SHA256=$(shasum -a 256 \
    ./libvlc-macho-metadata.json | awk '{print $1}')
if [ "${PUBLISHED_PROVENANCE_SHA256}" != "${STAGED_PROVENANCE_SHA256}" ]; then
    error "Published provenance record differs from its validated staging input."
fi
if [ "${PUBLISHED_MACHO_REPORT_SHA256}" != "${STAGED_MACHO_REPORT_SHA256}" ]; then
    error "Published Mach-O report differs from its validated staging input."
fi
PYTHONDONTWRITEBYTECODE=1 python3 - \
    "${SCRIPT_DIR}/libvlc-provenance.py" \
    ./libvlc-provenance.json \
    ./libvlc.xcframework <<'PYEOF'
import importlib.util
import sys
from pathlib import Path

module_path, provenance_path, published_path = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("swiftvlc_provenance", module_path)
if spec is None or spec.loader is None:
    raise SystemExit("could not load libVLC provenance implementation")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
record = module.load_record(provenance_path)
module.verify_recorded_artifact(record, published_path, "published XCFramework")
PYEOF
)

if [ -L ./libvlc.xcframework ]; then
    # rm of a final symlink removes that one Vendor entry and never follows it.
    rm -f ./libvlc.xcframework
elif [ -e ./libvlc.xcframework ]; then
    if [ ! -d ./libvlc.xcframework ]; then
        error "Existing Vendor/libvlc.xcframework is not a directory or symlink."
    fi
    if ! bind_directory_for_handoff \
        . libvlc.xcframework \
        "${PUBLISHED_ARTIFACT_REMOVAL_BINDING_NAME}" \
        "${PUBLISHED_ARTIFACT_REMOVAL_BINDING_CONTENT}"; then
        error "Could not safely authorize replacement of the existing XCFramework."
    fi
    if ! PYTHONDONTWRITEBYTECODE=1 python3 \
        "${SCRIPT_DIR}/detach-managed-build-directory.py" clean \
        --root . \
        --child libvlc.xcframework \
        --quarantine ".swiftvlc-published-artifact.removing-${BUILD_INVOCATION_ID}" \
        --marker-name "${PUBLISHED_ARTIFACT_REMOVAL_BINDING_NAME}" \
        --marker-content "${PUBLISHED_ARTIFACT_REMOVAL_BINDING_CONTENT}"; then
        error "Existing XCFramework replacement stopped safely; inspect the preserved Vendor quarantine."
    fi
fi
rm -f ./libvlc-provenance-a.json \
    ./libvlc-provenance.json \
    ./libvlc-reproducibility.json \
    ./libvlc-macho-metadata.json
# Publish in commit order with atomic no-replace renames. Provenance is last:
# if any earlier move fails, release.sh cannot mistake a partial handoff for a
# complete artifact, and the helper leaves all state in place for inspection.
if ! PYTHONDONTWRITEBYTECODE=1 python3 \
    "${SCRIPT_DIR}/detach-managed-build-directory.py" publish \
    --root . \
    --child "${PUBLISHING_CHILD}" \
    --marker-name "${BUILD_DIRECTORY_MARKER}" \
    --marker-content "${BUILD_DIRECTORY_MARKER_CONTENT}" \
    --binding-name "${PUBLISHING_BINDING_NAME}" \
    --binding-content "${PUBLISHING_BINDING_CONTENT}" \
    --entry libvlc.xcframework \
    --entry libvlc-macho-metadata.json \
    --entry libvlc-provenance.json; then
    error "Verified native artifact publication stopped safely; inspect the preserved Vendor publication state."
fi
)
info "Published verified native artifact: ${PUBLISHED_OUTPUT_DIR}/libvlc.xcframework"
)
# The published copy has already passed the exact tree-digest comparison.
# Retire the source staging tree through the same fd-relative cleanup used for
# the main external build directory. Its invocation-unique binding stays live
# for the entire output phase and authorizes this exact generation; a static
# ownership marker alone must never authorize a replacement at the public path.
if ! PYTHONDONTWRITEBYTECODE=1 python3 \
    "${SCRIPT_DIR}/detach-managed-build-directory.py" clean \
    --root . \
    --child "${STAGED_OUTPUT_CHILD}" \
    --quarantine ".swiftvlc-native-output.removing-${BUILD_INVOCATION_ID}" \
    --marker-name "${STAGED_OUTPUT_BINDING_NAME}" \
    --marker-content "${STAGED_OUTPUT_BINDING_CONTENT}"; then
    error "Published successfully, but could not safely retire native output staging."
fi

echo ""
info "Build complete!"
echo "  XCFramework: ${PUBLISHED_OUTPUT_DIR}/libvlc.xcframework"
echo "  Architectures:"
find "${PUBLISHED_OUTPUT_DIR}/libvlc.xcframework" -name "*.a" -exec lipo -info {} \;

local_end=$(date +%s)
local_total=$((local_end - BUILD_START_TIME))
local_mins=$((local_total / 60))
echo ""
echo "  Total time: ${local_mins}m$((local_total % 60))s"
echo ""
echo "To use: run 'swift build' in the SwiftVLC directory"
)
