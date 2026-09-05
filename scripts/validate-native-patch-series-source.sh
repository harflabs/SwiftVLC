#!/usr/bin/env bash
# Replay the frozen native patch series and run its pure source contracts.
#
# This deliberately does not configure or compile VLC. It is the inexpensive
# PR/release complement to the two clean XCFramework builds and physical-device
# qualification: patch applicability, final integrated source semantics, and
# mutation sensitivity can run on either Linux or macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
PINNED_VLC_COMMIT="c833c4be000b426d73ff4324bec574065f00e3df"
DEFAULT_VLC_REPOSITORY="https://github.com/videolan/vlc.git"

VLC_REPOSITORY="${SWIFTVLC_VLC_SOURCE_REPOSITORY:-$DEFAULT_VLC_REPOSITORY}"
WORK_ROOT="${SWIFTVLC_NATIVE_SOURCE_WORK_ROOT:-${SWIFTVLC_VALIDATION_TMP_ROOT:-${SWIFTVLC_EXTERNAL_TMPDIR:-${TMPDIR:-/tmp}}}}"
KEEP_WORKTREE=no
REPLAY_DIR=""

usage() {
    cat >&2 <<EOF
Usage: $0 [--work-root <external-temp-parent>] [--vlc-repository <url-or-path>]
          [--keep-worktree]

The repository override is intended for offline/local validation. The exact
commit and in-repository patch manifest remain mandatory.
EOF
}

fail() {
    echo "ERROR native source replay: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-root)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            WORK_ROOT="$2"
            shift 2
            ;;
        --vlc-repository)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            VLC_REPOSITORY="$2"
            shift 2
            ;;
        --keep-worktree)
            KEEP_WORKTREE=yes
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown native source replay option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

[[ -n "$VLC_REPOSITORY" ]] || fail "VLC repository must not be empty"
if ! python3 "$SCRIPT_DIR/verify-native-validator-assets.py"; then
    fail "native validator asset manifest verification failed"
fi
WORK_ROOT=$(python3 - "$WORK_ROOT" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve(strict=False))
PY
)
case "$WORK_ROOT/" in
    "$REPO_ROOT/"|"$REPO_ROOT/"*)
        fail "work root must be outside the SwiftVLC checkout: $WORK_ROOT"
        ;;
esac
mkdir -p "$WORK_ROOT"
WORK_ROOT="$(cd "$WORK_ROOT" && pwd -P)"
case "$WORK_ROOT/" in
    "$REPO_ROOT/"|"$REPO_ROOT/"*)
        fail "work root must be outside the SwiftVLC checkout: $WORK_ROOT"
        ;;
esac

cleanup() {
    local exit_status=$?
    local cleanup_target=""

    trap - EXIT INT TERM
    if [[ -z "$REPLAY_DIR" || ( ! -e "$REPLAY_DIR" && ! -L "$REPLAY_DIR" ) ]]; then
        exit "$exit_status"
    fi
    if [[ "$KEEP_WORKTREE" = yes ]]; then
        echo "Retained native source replay: $REPLAY_DIR" >&2
        exit "$exit_status"
    fi
    case "$REPLAY_DIR" in
        "$WORK_ROOT"/.swiftvlc-native-source.*)
            ;;
        *)
            echo "Refusing to clean unexpected replay path: $REPLAY_DIR" >&2
            exit 1
            ;;
    esac

    # Rename first so Finder cannot repopulate a visible directory with
    # .DS_Store while it is being removed from an external macOS volume.
    cleanup_target="$WORK_ROOT/.swiftvlc-native-source.cleanup.$$.$RANDOM"
    if [[ ! -e "$cleanup_target" && ! -L "$cleanup_target" ]] \
        && mv -- "$REPLAY_DIR" "$cleanup_target"; then
        REPLAY_DIR="$cleanup_target"
    fi
    rm -rf -- "$REPLAY_DIR" 2>/dev/null || true
    if [[ -e "$REPLAY_DIR" || -L "$REPLAY_DIR" ]]; then
        sleep 1
        rm -rf -- "$REPLAY_DIR" 2>/dev/null || true
    fi
    if [[ -e "$REPLAY_DIR" || -L "$REPLAY_DIR" ]]; then
        echo "ERROR native source replay: could not clean replay directory: $REPLAY_DIR" >&2
        exit_status=1
    fi
    exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

section() {
    echo ""
    echo "==> $*"
}

section "Testing the shared extension-version resolver"
python3 -B -m unittest \
    "$SCRIPT_DIR/tests/test_pip_extension_version.py" \
    "$SCRIPT_DIR/patches/validation/test_pip_extension_version.py"

section "Verifying the frozen patch manifest"
if ! manifest_listing=$(
    "$SCRIPT_DIR/verify-patch-manifest.sh" "$PATCHES_DIR"
); then
    fail "patch manifest verification failed"
fi
patch_names=()
while IFS= read -r patch_name; do
    [[ -n "$patch_name" ]] || continue
    case "$patch_name" in
        /*|..|../*|*/..|*/../*)
            fail "unsafe patch path returned by manifest verifier: $patch_name"
            ;;
    esac
    patch_names+=("$patch_name")
done <<< "$manifest_listing"
[[ "${#patch_names[@]}" -gt 0 ]] || fail "verified patch manifest is empty"
echo "Verified ${#patch_names[@]} patch artifacts."

REPLAY_DIR=$(mktemp -d "$WORK_ROOT/.swiftvlc-native-source.XXXXXX") \
    || fail "could not create replay directory below $WORK_ROOT"
VLC_SOURCE_ROOT="$REPLAY_DIR/vlc"

section "Fetching pinned VLC source"
echo "Repository: $VLC_REPOSITORY"
echo "Commit:     $PINNED_VLC_COMMIT"
git init --quiet "$VLC_SOURCE_ROOT"
git -C "$VLC_SOURCE_ROOT" remote add origin "$VLC_REPOSITORY"
if ! git -C "$VLC_SOURCE_ROOT" \
    -c protocol.version=2 \
    fetch --quiet --no-tags --depth=1 --filter=blob:none \
    origin "$PINNED_VLC_COMMIT"; then
    fail "could not fetch pinned VLC commit $PINNED_VLC_COMMIT"
fi
git -C "$VLC_SOURCE_ROOT" \
    -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
actual_commit=$(git -C "$VLC_SOURCE_ROOT" rev-parse HEAD)
[[ "$actual_commit" = "$PINNED_VLC_COMMIT" ]] \
    || fail "checkout resolved $actual_commit, expected $PINNED_VLC_COMMIT"

section "Applying the ordered native patch series"
patch_index=0
for patch_name in "${patch_names[@]}"; do
    patch_index=$((patch_index + 1))
    patch_path="$PATCHES_DIR/$patch_name"
    printf '[%02d/%02d] %s\n' \
        "$patch_index" "${#patch_names[@]}" "$patch_name"
    if ! git -C "$VLC_SOURCE_ROOT" apply --check "$patch_path"; then
        fail "patch does not apply at its manifest boundary: $patch_name"
    fi
    git -C "$VLC_SOURCE_ROOT" apply "$patch_path"
done

section "Checking final patch whitespace"
git -C "$VLC_SOURCE_ROOT" diff --check

section "Validating libaom 3.13.2 and NASM 3 detection"
"$SCRIPT_DIR/validate-aom-nasm3-detection.sh" \
    "$VLC_SOURCE_ROOT" "$REPLAY_DIR/aom-nasm3-validation"

section "Validating headless video-output teardown lifecycle"
"$SCRIPT_DIR/validate-headless-vout-teardown.sh" \
    --source-root "$VLC_SOURCE_ROOT" \
    --work-root "$REPLAY_DIR/headless-vout-teardown-validation"

section "Validating adaptive ES codec-configuration recycling"
python3 -B \
    "$SCRIPT_DIR/patches/validation/adaptive-es-recycling-source-check.py" \
    "$VLC_SOURCE_ROOT" \
    "$SCRIPT_DIR/patches/0042-adaptive-es-recycling-extradata-identity.patch"

section "Validating exact integrated extension version 10"
"$SCRIPT_DIR/validate-native-extension-contract.sh" \
    --source-root "$VLC_SOURCE_ROOT" \
    --expected-version 10 \
    --require-apple-audio-session-leases \
    --run-mutations

section "Validating ordered semantic subtitle-text snapshots"
subtitle_snapshot_compiler="${CC:-cc}"
command -v "$subtitle_snapshot_compiler" >/dev/null 2>&1 \
    || fail "C compiler not found for subtitle-text snapshot proof: $subtitle_snapshot_compiler"
"$subtitle_snapshot_compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    "$SCRIPT_DIR/patches/validation/subtitle-text-snapshot.c" \
    -o "$REPLAY_DIR/subtitle-text-snapshot"
"$REPLAY_DIR/subtitle-text-snapshot"

section "Validating native PiP output identity and race semantics"
python3 -B \
    "$SCRIPT_DIR/patches/validation/native-pip-output-identity-source-check.py" \
    "$VLC_SOURCE_ROOT" \
    "$SCRIPT_DIR/patches/0041-native-pip-output-identity.patch"
pip_race_compiler="${CC:-cc}"
command -v "$pip_race_compiler" >/dev/null 2>&1 \
    || fail "C compiler not found for native PiP race proof: $pip_race_compiler"
"$pip_race_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pthread \
    "$SCRIPT_DIR/patches/validation/native-pip-output-identity-race.c" \
    -o "$REPLAY_DIR/native-pip-output-identity-race"
"$REPLAY_DIR/native-pip-output-identity-race"

section "Validating strict frame-step source semantics"
python3 -B \
    "$SCRIPT_DIR/patches/validation/strict-frame-step-source-check.py" \
    "$VLC_SOURCE_ROOT"

section "Validating timestamp-bearing vmem source semantics"
python3 -B \
    "$SCRIPT_DIR/patches/validation/vmem-picture-pts-source-check.py" \
    "$VLC_SOURCE_ROOT"

section "Validating effective-rate source semantics"
python3 -B \
    "$SCRIPT_DIR/patches/validation/effective-playback-rate-event-source-check.py" \
    "$VLC_SOURCE_ROOT"

section "Validating Apple audio reset and lease source semantics"
python3 -B \
    "$SCRIPT_DIR/patches/validation/audio-media-services-reset-source-check.py" \
    "$VLC_SOURCE_ROOT" "$REPO_ROOT"

section "Native patch-series source contracts passed"
echo "Pinned VLC commit: $actual_commit"
echo "Applied patches:   ${#patch_names[@]}"
echo "Extension version: 10 (apple-audio-session-leases required)"
