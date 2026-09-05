#!/bin/bash
# Compile and run patch 0027's ABI/burst/EOF proof against the exact macOS
# archive and checked-in headers that the XCFramework will ship.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCFRAMEWORK="${1:-$REPO_ROOT/Vendor/libvlc.xcframework}"
VLC_SOURCE_ROOT="${2:-${SWIFTVLC_STRICT_VLC_SOURCE_ROOT:-}}"
VLC_BUILD_ROOT="${3:-${SWIFTVLC_STRICT_VLC_BUILD_ROOT:-}}"
EXPECTED_EXTENSION_VERSION="${SWIFTVLC_EXPECTED_EXTENSION_VERSION:-}"
REQUIRE_APPLE_AUDIO_SESSION_LEASES="${SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES:-no}"
ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"
PUBLIC_HEADER="$REPO_ROOT/Sources/CLibVLC/include/vlc/libvlc_media_player.h"
EVENTS_HEADER="$REPO_ROOT/Sources/CLibVLC/include/vlc/libvlc_events.h"
VERSION_RESOLVER="$SCRIPT_DIR/patches/validation/pip_extension_version.py"
EXPECTED_VERSION_RESOLVER_SHA="1582e0915d13a177fbe545099a1ed52696d1b60cfa5dbfd6a35a60943ccfcd36"

actual_version_resolver_sha=$(shasum -a 256 "$VERSION_RESOLVER" | awk '{print $1}')
if [[ "$actual_version_resolver_sha" != "$EXPECTED_VERSION_RESOLVER_SHA" ]]; then
  echo "Strict frame-step extension-version resolver hash mismatch:" >&2
  echo "  expected $EXPECTED_VERSION_RESOLVER_SHA" >&2
  echo "  actual   $actual_version_resolver_sha" >&2
  exit 1
fi

# The checked-in public header can intentionally be newer than Vendor while a
# beta native archive is being rebuilt. Never infer an archive's expected ABI
# from that header alone. A source-linked invocation resolves and validates the
# exact source tree; archive-only callers must state their expected version.
if [[ "$EXPECTED_EXTENSION_VERSION" == 9 ||
      "$EXPECTED_EXTENSION_VERSION" == 10 ]]; then
  REQUIRE_APPLE_AUDIO_SESSION_LEASES=yes
fi
if [[ -n "$VLC_SOURCE_ROOT" ]]; then
  version_arguments=(--source-root "$VLC_SOURCE_ROOT")
  if [[ -n "$EXPECTED_EXTENSION_VERSION" ]]; then
    version_arguments+=(--expected-version "$EXPECTED_EXTENSION_VERSION")
  fi
  if [[ "$REQUIRE_APPLE_AUDIO_SESSION_LEASES" == yes ]]; then
    version_arguments+=(
      --require-same-version-group apple-audio-session-leases
    )
  fi
  EXPECTED_EXTENSION_VERSION=$(
    python3 -B "$VERSION_RESOLVER" "${version_arguments[@]}"
  )
  if [[ "$EXPECTED_EXTENSION_VERSION" -ge 9 &&
        "$REQUIRE_APPLE_AUDIO_SESSION_LEASES" != yes ]]; then
    REQUIRE_APPLE_AUDIO_SESSION_LEASES=yes
    version_arguments+=(
      --require-same-version-group apple-audio-session-leases
    )
  fi
  if [[ "$EXPECTED_EXTENSION_VERSION" -ge 8 &&
        "$REQUIRE_APPLE_AUDIO_SESSION_LEASES" == yes ]]; then
    python3 -B "$VERSION_RESOLVER" "${version_arguments[@]}" \
      --vendored-public-header "$PUBLIC_HEADER" \
      --vendored-events-header "$EVENTS_HEADER" >/dev/null
  fi
elif [[ -z "$EXPECTED_EXTENSION_VERSION" ]]; then
  echo "Archive-only strict frame-step validation requires an explicit expected extension version." >&2
  echo "Set SWIFTVLC_EXPECTED_EXTENSION_VERSION; checked-in headers are not archive identity." >&2
  exit 2
elif [[ "$REQUIRE_APPLE_AUDIO_SESSION_LEASES" == yes ]]; then
  echo "A required same-version source group cannot be proved without a VLC source root." >&2
  exit 2
fi

case "$EXPECTED_EXTENSION_VERSION" in
  4|5|6|7|8|9|10) ;;
  *)
    echo "Expected PiP extension version must be an integer from 4 through 10: $EXPECTED_EXTENSION_VERSION" >&2
    exit 2
    ;;
esac
VERSION_DEFINE="-DSWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION=$EXPECTED_EXTENSION_VERSION"
LEASE_DEFINE="-DSWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES=$([[ "$REQUIRE_APPLE_AUDIO_SESSION_LEASES" == yes ]] && echo 1 || echo 0)"

if [[ -n "$VLC_SOURCE_ROOT" ]]; then
  python3 -B \
    "$SCRIPT_DIR/patches/validation/strict-frame-step-source-check.py" \
    "$VLC_SOURCE_ROOT"
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Strict frame-step source contract passed at extension version $EXPECTED_EXTENSION_VERSION; runtime validation skipped (no macOS slice)."
  exit 0
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-strict-frame-step.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

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

clang -std=c11 -o "$WORK_DIR/probe" \
  "$VERSION_DEFINE" \
  "$LEASE_DEFINE" \
  "$SCRIPT_DIR/patches/validation/strict-frame-step-probe.c" \
  -I "$REPO_ROOT/Sources/CLibVLC/include" "$ARCHIVE" \
  "${FRAMEWORKS[@]}"

"$WORK_DIR/probe" "$REPO_ROOT/Tests/SwiftVLCTests/Fixtures/twosec.mp4"

if [[ -n "$VLC_SOURCE_ROOT" || -n "$VLC_BUILD_ROOT" ]]; then
  if [[ -z "$VLC_SOURCE_ROOT" || -z "$VLC_BUILD_ROOT" ]]; then
    echo "Both VLC source and build roots are required for source-linked validation." >&2
    exit 1
  fi
  if [[ -f "$VLC_BUILD_ROOT/config.h" ]]; then
    VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT" && pwd)"
  elif [[ -f "$VLC_BUILD_ROOT/build/config.h" ]]; then
    VLC_BUILD_DIR="$(cd "$VLC_BUILD_ROOT/build" && pwd)"
  else
    echo "Strict frame-step VLC host config.h not found under: $VLC_BUILD_ROOT" >&2
    exit 1
  fi
  for path in \
    "$VLC_SOURCE_ROOT/include/vlc/libvlc_media_player.h" \
    "$VLC_SOURCE_ROOT/include/vlc_vmem_configuration.h" \
    "$VLC_SOURCE_ROOT/src/player/player.h" \
    "$VLC_BUILD_DIR/config.h"; do
    if [[ ! -f "$path" ]]; then
      echo "Strict frame-step source-linked input not found: $path" >&2
      exit 1
    fi
  done

  clang -std=gnu17 -DHAVE_CONFIG_H -DSWIFTVLC_SOURCE_LINKED_PROBE \
    "$VERSION_DEFINE" \
    "$LEASE_DEFINE" \
    -o "$WORK_DIR/source-linked-probe" \
    "$SCRIPT_DIR/patches/validation/strict-frame-step-probe.c" \
    -I "$VLC_BUILD_DIR" -I "$VLC_SOURCE_ROOT" \
    -I "$VLC_SOURCE_ROOT/include" -I "$VLC_SOURCE_ROOT/lib" \
    -I "$VLC_SOURCE_ROOT/src" -I "$VLC_BUILD_DIR/include" \
    "$ARCHIVE" "${FRAMEWORKS[@]}"
  "$WORK_DIR/source-linked-probe" \
    "$REPO_ROOT/Tests/SwiftVLCTests/Fixtures/twosec.mp4"

  clang -std=gnu17 -DHAVE_CONFIG_H -o "$WORK_DIR/vmem-race" \
    "$SCRIPT_DIR/patches/validation/vmem-configuration-race.c" \
    -I "$VLC_BUILD_DIR" -I "$VLC_SOURCE_ROOT/include" \
    -I "$VLC_BUILD_DIR/include" "$ARCHIVE" "${FRAMEWORKS[@]}"
  "$WORK_DIR/vmem-race"
else
  echo "Strict frame-step source-linked listener/overflow/vmem race gates skipped: pass VLC source and build roots." >&2
fi

echo "Apple strict-frame pixel identity: PENDING (device-only)."
echo "Qualification invariant: $SCRIPT_DIR/patches/validation/strict-frame-step-apple-device.md"
