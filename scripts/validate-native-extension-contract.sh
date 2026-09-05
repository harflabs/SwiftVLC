#!/bin/bash
# Bind the ordered patch intent, patched VLC source, vendored public headers,
# and linked candidate archive to one exact SwiftVLC native extension version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$SCRIPT_DIR/patches/validation/pip_extension_version.py"
PROBE="$SCRIPT_DIR/patches/validation/native-extension-version-probe.c"

SOURCE_ROOT=""
XCFRAMEWORK=""
EXPECTED_VERSION=""
REQUIRE_LEASES=no
RUN_MUTATIONS=no

usage() {
    cat >&2 <<EOF
Usage: $0 --expected-version <1..10> [--source-root <patched-vlc>] \\
  [--xcframework <candidate>] [--require-apple-audio-session-leases] \\
  [--run-mutations]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            SOURCE_ROOT="$2"
            shift 2
            ;;
        --xcframework)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            XCFRAMEWORK="$2"
            shift 2
            ;;
        --expected-version)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --require-apple-audio-session-leases)
            REQUIRE_LEASES=yes
            shift
            ;;
        --run-mutations)
            RUN_MUTATIONS=yes
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown native extension contract option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ ! "$EXPECTED_VERSION" =~ ^([1-9]|10)$ ]]; then
    echo "An exact expected extension version from 1 through 10 is required." >&2
    exit 2
fi
if [[ "$REQUIRE_LEASES" = yes ]] && (( EXPECTED_VERSION < 8 )); then
    echo "Apple audio-session leases require extension version 8 or newer." >&2
    exit 2
fi
if (( EXPECTED_VERSION >= 9 )); then
    # v9 succeeds the final v8+0033 profile. Do not let omission of an optional
    # command-line flag turn an inherited safety contract back into an option.
    REQUIRE_LEASES=yes
fi
if [[ -z "$SOURCE_ROOT" && -z "$XCFRAMEWORK" ]]; then
    echo "At least one of --source-root or --xcframework is required." >&2
    exit 2
fi

# SwiftVLC deliberately keeps weak definitions so an older released static
# archive remains linkable. Prove those compatibility paths cannot advertise
# v9/v10 or mutate native state before evaluating a source tree or an archive.
python3 -B - "$RESOLVER" "$REPO_ROOT/Sources/CLibVLC/shim.c" <<'PY'
import importlib.util
from pathlib import Path
import sys

resolver_path = Path(sys.argv[1])
shim_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "swiftvlc_pip_extension_version", resolver_path
)
if spec is None or spec.loader is None:
    raise SystemExit(f"cannot import native extension resolver: {resolver_path}")
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)
try:
    resolver.validate_weak_compatibility_shim(
        shim_path.read_text(encoding="utf-8")
    )
except (OSError, resolver.ExtensionVersionError) as error:
    raise SystemExit(f"FAIL native extension weak compatibility: {error}")
PY

if [[ -n "$SOURCE_ROOT" ]]; then
    if (( EXPECTED_VERSION < 4 )); then
        echo "Source composition proof is defined for extension versions 4 through 10." >&2
        exit 2
    fi
    if [[ ! -d "$SOURCE_ROOT" ]]; then
        echo "Patched VLC source root not found: $SOURCE_ROOT" >&2
        exit 2
    fi
    resolver_args=(
        --source-root "$SOURCE_ROOT"
        --expected-version "$EXPECTED_VERSION"
        --vendored-public-header \
            "$REPO_ROOT/Sources/CLibVLC/include/vlc/libvlc_media_player.h"
        --vendored-events-header \
            "$REPO_ROOT/Sources/CLibVLC/include/vlc/libvlc_events.h"
    )
    if [[ "$REQUIRE_LEASES" = yes ]]; then
        resolver_args+=(
            --require-same-version-group apple-audio-session-leases
        )
    fi
    if [[ "$RUN_MUTATIONS" = yes ]]; then
        resolver_args+=(--run-mutations)
    fi
    resolved=$(python3 "$RESOLVER" "${resolver_args[@]}")
    if [[ "$resolved" != "$EXPECTED_VERSION" ]]; then
        echo "Source resolver returned $resolved, expected $EXPECTED_VERSION" >&2
        exit 1
    fi
    echo "PASS native extension source/vendored contract: version=$resolved leases=$REQUIRE_LEASES"
fi

if [[ -n "$XCFRAMEWORK" ]]; then
    if [[ ! -d "$XCFRAMEWORK" ]]; then
        echo "Native extension XCFramework not found: $XCFRAMEWORK" >&2
        exit 1
    fi
    XCFRAMEWORK="$(cd "$XCFRAMEWORK" && pwd -P)"
    if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
        echo "Exact linked native extension validation requires macOS and Xcode." >&2
        exit 1
    fi

    VALIDATION_TMP_ROOT="${SWIFTVLC_VALIDATION_TMP_ROOT:-${SWIFTVLC_EXTERNAL_TMPDIR:-${TMPDIR:-/tmp}}}"
    mkdir -p "$VALIDATION_TMP_ROOT"
    WORK_DIR=$(mktemp -d "$VALIDATION_TMP_ROOT/swiftvlc-native-extension.XXXXXX")
    cleanup() {
        rm -rf -- "$WORK_DIR"
    }
    trap cleanup EXIT INT TERM
    mkdir -p "$WORK_DIR/module-cache" "$WORK_DIR/compiler-tmp"
    export TMPDIR="$WORK_DIR/compiler-tmp"
    export CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache"

    CLANG=$(xcrun --sdk macosx --find clang)
    LIPO=$(xcrun --find lipo)
    NM=$(xcrun --find nm)
    MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
    LIBRARIES_TSV="$WORK_DIR/xcframework-libraries.tsv"

    # The runtime probe can execute only the host architecture, but a release
    # artifact is one contract spanning every declared XCFramework library and
    # architecture. Parse the plist as the authoritative slice inventory and
    # independently reject missing, extra, linked, or undeclared archives.
    python3 - "$XCFRAMEWORK" > "$LIBRARIES_TSV" <<'PY'
from pathlib import Path, PurePosixPath
import plistlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"invalid native extension XCFramework: {message}")


root = Path(sys.argv[1])
plist_path = root / "Info.plist"
if (
    plist_path.is_symlink()
    or not plist_path.is_file()
    or plist_path.resolve() != plist_path.absolute()
):
    fail(f"missing, linked, or non-regular Info.plist: {plist_path}")
try:
    info = plistlib.loads(plist_path.read_bytes())
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"cannot parse {plist_path}: {error}")

libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or not libraries:
    fail("AvailableLibraries must be a nonempty array")

token = re.compile(r"[A-Za-z0-9_.+-]+")
arch_token = re.compile(r"[A-Za-z0-9_]+")
records = []
declared_paths = set()
identifiers = set()
for index, library in enumerate(libraries):
    if not isinstance(library, dict):
        fail(f"AvailableLibraries[{index}] is not a dictionary")
    identifier = library.get("LibraryIdentifier")
    if not isinstance(identifier, str) or token.fullmatch(identifier) is None:
        fail(f"AvailableLibraries[{index}] has unsafe LibraryIdentifier")
    if identifier in identifiers:
        fail(f"duplicate LibraryIdentifier: {identifier}")
    identifiers.add(identifier)

    library_path = library.get("LibraryPath")
    if not isinstance(library_path, str) or not library_path:
        fail(f"{identifier} has no LibraryPath")
    path = PurePosixPath(library_path)
    if (
        path.is_absolute()
        or not path.parts
        or any(part in ("", ".", "..") or token.fullmatch(part) is None
               for part in path.parts)
        or path.suffix != ".a"
    ):
        fail(f"{identifier} has unsafe static LibraryPath: {library_path!r}")
    binary_path = library.get("BinaryPath")
    if binary_path is not None and binary_path != library_path:
        fail(
            f"{identifier} BinaryPath {binary_path!r} differs from "
            f"LibraryPath {library_path!r}"
        )

    architectures = library.get("SupportedArchitectures")
    if (
        not isinstance(architectures, list)
        or not architectures
        or any(not isinstance(arch, str) or arch_token.fullmatch(arch) is None
               for arch in architectures)
        or len(set(architectures)) != len(architectures)
    ):
        fail(f"{identifier} has invalid SupportedArchitectures")

    platform = library.get("SupportedPlatform")
    if not isinstance(platform, str) or token.fullmatch(platform) is None:
        fail(f"{identifier} has invalid SupportedPlatform")
    variant = library.get("SupportedPlatformVariant", "-")
    if not isinstance(variant, str) or token.fullmatch(variant) is None:
        fail(f"{identifier} has invalid SupportedPlatformVariant")

    relative = PurePosixPath(identifier).joinpath(path).as_posix()
    if relative in declared_paths:
        fail(f"duplicate declared archive path: {relative}")
    declared_paths.add(relative)
    archive = root.joinpath(*PurePosixPath(relative).parts)
    if (
        archive.is_symlink()
        or not archive.is_file()
        or archive.resolve() != archive.absolute()
    ):
        fail(f"missing, linked, or non-regular declared archive: {relative}")
    records.append(
        (identifier, relative, ",".join(sorted(architectures)), platform, variant)
    )

actual_paths = set()
for archive in root.rglob("*.a"):
    relative = archive.relative_to(root).as_posix()
    if (
        archive.is_symlink()
        or not archive.is_file()
        or archive.resolve() != archive.absolute()
    ):
        fail(f"linked or non-regular archive in artifact: {relative}")
    actual_paths.add(relative)
if actual_paths != declared_paths:
    missing = sorted(declared_paths.difference(actual_paths))
    extra = sorted(actual_paths.difference(declared_paths))
    fail(f"archive inventory differs: missing={missing} extra={extra}")

for record in sorted(records):
    print("\t".join(record))
PY

    VERSION_1_SYMBOLS=(
        swiftvlc_libvlc_pip_extensions_version
        swiftvlc_libvlc_media_player_get_media_length_snapshot
        swiftvlc_libvlc_video_set_format_callbacks_ex
    )
    VERSION_2_SYMBOLS=(
        swiftvlc_libvlc_media_player_get_playback_snapshot
    )
    VERSION_4_SYMBOLS=(
        swiftvlc_libvlc_media_player_request_next_frame
        swiftvlc_libvlc_media_player_cancel_next_frame_request
        swiftvlc_libvlc_video_set_display_status_callback
        swiftvlc_libvlc_video_set_callbacks_atomic
    )
    VERSION_5_SYMBOLS=(
        swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot
    )
    VERSION_6_SYMBOLS=(
        swiftvlc_libvlc_video_set_callbacks_atomic_v2
    )
    VERSION_8_SYMBOLS=(
        swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot
        swiftvlc_libvlc_media_player_set_pause_without_reset_authorization
    )
    VERSION_9_SYMBOLS=(
        swiftvlc_libvlc_media_player_set_pip_playback_identity
    )
    VERSION_10_SYMBOLS=(
        swiftvlc_libvlc_media_player_set_subtitle_text_snapshot_callback
    )
    LEASE_SYMBOLS=(
        swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease
        swiftvlc_libvlc_media_player_release_apple_audio_session_lease
    )

    REQUIRED_SYMBOLS=("${VERSION_1_SYMBOLS[@]}")
    FUTURE_SYMBOLS=()
    if (( EXPECTED_VERSION >= 2 )); then
        REQUIRED_SYMBOLS+=("${VERSION_2_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_2_SYMBOLS[@]}")
    fi
    if (( EXPECTED_VERSION >= 4 )); then
        REQUIRED_SYMBOLS+=("${VERSION_4_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_4_SYMBOLS[@]}")
    fi
    if (( EXPECTED_VERSION >= 5 )); then
        REQUIRED_SYMBOLS+=("${VERSION_5_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_5_SYMBOLS[@]}")
    fi
    if (( EXPECTED_VERSION >= 6 )); then
        REQUIRED_SYMBOLS+=("${VERSION_6_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_6_SYMBOLS[@]}")
    fi
    if (( EXPECTED_VERSION >= 8 )); then
        REQUIRED_SYMBOLS+=("${VERSION_8_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_8_SYMBOLS[@]}")
    fi
    if (( EXPECTED_VERSION >= 9 )); then
        REQUIRED_SYMBOLS+=("${VERSION_9_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_9_SYMBOLS[@]}")
    fi
    if (( EXPECTED_VERSION >= 10 )); then
        REQUIRED_SYMBOLS+=("${VERSION_10_SYMBOLS[@]}")
    else
        FUTURE_SYMBOLS+=("${VERSION_10_SYMBOLS[@]}")
    fi

    symbol_definition_counts() {
        local nm_output="$1"
        local symbol="$2"
        awk -v target="_$symbol" \
            '$NF == target && $0 !~ /\(undefined\)/ {
                 total += 1
                 if ($0 ~ /\(__TEXT,__text\)/ &&
                     $0 !~ /(^|[[:space:]])weak([[:space:]]|$)/)
                     strong_text += 1
             }
             END { print strong_text + 0 ":" total + 0 }' "$nm_output"
    }

    normalize_actual_architectures() {
        printf '%s\n' "$1" | tr ' ' '\n' | LC_ALL=C sort | \
            awk 'NF { if (result != "") result = result ","; result = result $0 }
                 END { print result }'
    }

    archive_count=0
    architecture_count=0
    macos_archive=""
    macos_architectures=""
    macos_library_count=0
    lease_surface_state=""
    while IFS=$'\t' read -r library_id archive_relative \
            declared_architectures platform variant; do
        [[ -n "$library_id" ]] || continue
        archive_count=$((archive_count + 1))
        archive="$XCFRAMEWORK/$archive_relative"
        actual_architectures=$("$LIPO" -archs "$archive")
        actual_architectures=$(normalize_actual_architectures \
            "$actual_architectures")
        if [[ "$actual_architectures" != "$declared_architectures" ]]; then
            echo "XCFramework architecture mismatch for $library_id:" >&2
            echo "  declared $declared_architectures" >&2
            echo "  actual   $actual_architectures" >&2
            exit 1
        fi

        if [[ "$platform" = macos && "$variant" = - ]]; then
            macos_library_count=$((macos_library_count + 1))
            macos_archive="$archive"
            macos_architectures="$actual_architectures"
        fi

        old_ifs="$IFS"
        IFS=,
        for architecture in $declared_architectures; do
            architecture_count=$((architecture_count + 1))
            nm_output="$WORK_DIR/nm-${archive_count}-${architecture}.txt"
            nm_errors="$WORK_DIR/nm-${archive_count}-${architecture}.err"
            if ! "$NM" -arch "$architecture" -gm "$archive" \
                    > "$nm_output" 2> "$nm_errors"; then
                echo "Could not inspect $library_id/$architecture symbols." >&2
                sed -n '1,20p' "$nm_errors" >&2
                exit 1
            fi
            for symbol in "${REQUIRED_SYMBOLS[@]}"; do
                counts=$(symbol_definition_counts "$nm_output" "$symbol")
                strong_text_count=${counts%%:*}
                definition_count=${counts#*:}
                if [[ "$strong_text_count" != 1 || "$definition_count" != 1 ]]; then
                    echo "Native extension symbol is not exactly one strong text definition:" >&2
                    echo "  $library_id/$architecture: $symbol strong=$strong_text_count definitions=$definition_count" >&2
                    exit 1
                fi
            done
            # Bash 3.2 treats expansion of an explicitly empty array as an
            # unbound variable under `set -u`. Version 10 has no future group,
            # so guard the only empty-array boundary before expanding it.
            if (( EXPECTED_VERSION < 10 )); then
                for symbol in "${FUTURE_SYMBOLS[@]}"; do
                    counts=$(symbol_definition_counts "$nm_output" "$symbol")
                    definition_count=${counts#*:}
                    if [[ "$definition_count" != 0 ]]; then
                        echo "Future native extension symbol is present:" >&2
                        echo "  $library_id/$architecture: $symbol definitions=$definition_count" >&2
                        exit 1
                    fi
                done
            fi

            lease_acquire_counts=$(symbol_definition_counts "$nm_output" \
                "${LEASE_SYMBOLS[0]}")
            lease_release_counts=$(symbol_definition_counts "$nm_output" \
                "${LEASE_SYMBOLS[1]}")
            lease_acquire_strong=${lease_acquire_counts%%:*}
            lease_acquire_total=${lease_acquire_counts#*:}
            lease_release_strong=${lease_release_counts%%:*}
            lease_release_total=${lease_release_counts#*:}
            if [[ "$lease_acquire_total" = 0 && "$lease_release_total" = 0 ]]; then
                current_lease_state=absent
            elif [[ "$lease_acquire_strong" = 1 && "$lease_acquire_total" = 1 &&
                    "$lease_release_strong" = 1 && "$lease_release_total" = 1 ]]; then
                current_lease_state=full
            else
                echo "Apple audio-session lease symbol group is partial or duplicated:" >&2
                echo "  $library_id/$architecture: acquire=$lease_acquire_counts release=$lease_release_counts (strong:total)" >&2
                exit 1
            fi
            if (( EXPECTED_VERSION < 8 )) && \
                    [[ "$current_lease_state" != absent ]]; then
                echo "Future Apple audio-session lease symbols are present:" >&2
                echo "  $library_id/$architecture" >&2
                exit 1
            fi
            if [[ "$REQUIRE_LEASES" = yes && "$current_lease_state" != full ]]; then
                echo "Required Apple audio-session lease symbols are absent:" >&2
                echo "  $library_id/$architecture" >&2
                exit 1
            fi
            if [[ -z "$lease_surface_state" ]]; then
                lease_surface_state="$current_lease_state"
            elif [[ "$lease_surface_state" != "$current_lease_state" ]]; then
                echo "Apple audio-session lease surface differs across architectures:" >&2
                echo "  expected $lease_surface_state, $library_id/$architecture is $current_lease_state" >&2
                exit 1
            fi
        done
        IFS="$old_ifs"
    done < "$LIBRARIES_TSV"

    if [[ "$archive_count" = 0 || "$architecture_count" = 0 ]]; then
        echo "XCFramework contains no declared static library architectures." >&2
        exit 1
    fi
    if [[ "$macos_library_count" -gt 1 ]]; then
        echo "XCFramework declares more than one unmodified macOS library." >&2
        exit 1
    fi
    LINK_SYMBOL_REQUIREMENTS=("${REQUIRED_SYMBOLS[@]}")
    PROBE_REQUIRE_LEASES=0
    if [[ "$lease_surface_state" = full ]]; then
        LINK_SYMBOL_REQUIREMENTS+=("${LEASE_SYMBOLS[@]}")
        PROBE_REQUIRE_LEASES=1
    fi

    runtime_result=skipped
    if [[ "$macos_library_count" = 0 ]]; then
        echo "Exact runtime version probe skipped: XCFramework has no macOS library."
    else
        HOST_ARCH=$(uname -m)
        case ",$macos_architectures," in
            *",$HOST_ARCH,"*)
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
                LINK_SYMBOLS=()
                for symbol in "${LINK_SYMBOL_REQUIREMENTS[@]}"; do
                    LINK_SYMBOLS+=("-Wl,-u,_$symbol")
                done

                "$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
                    "-DSWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION=$EXPECTED_VERSION" \
                    "-DSWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES=$PROBE_REQUIRE_LEASES" \
                    -I "$REPO_ROOT/Sources/CLibVLC/include" \
                    "$PROBE" "$macos_archive" -o "$WORK_DIR/version-probe" \
                    "${LINK_SYMBOLS[@]}" "${FRAMEWORKS[@]}"
                actual=$("$WORK_DIR/version-probe")
                if [[ "$actual" != "$EXPECTED_VERSION" ]]; then
                    echo "Linked probe returned $actual, expected $EXPECTED_VERSION" >&2
                    exit 1
                fi
                runtime_result="$actual"
                ;;
            *)
                echo "Exact runtime version probe skipped: macOS library lacks host architecture $HOST_ARCH ($macos_architectures)."
                ;;
        esac
    fi
    echo "PASS native extension archive contract: expected=$EXPECTED_VERSION runtime=$runtime_result slices=$archive_count architectures=$architecture_count symbols=${#LINK_SYMBOL_REQUIREMENTS[@]} leases=$lease_surface_state"
fi
